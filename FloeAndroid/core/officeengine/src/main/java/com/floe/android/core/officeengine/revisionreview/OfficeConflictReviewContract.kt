// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.revisionreview

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import java.util.Locale

/** The real relationship between the open-time source and the live original. */
enum class OfficeConflictReviewState {
    /** The live original still carries the open-time identity. */
    UNCHANGED,

    /** The live original is a different immutable version. */
    CHANGED,

    /** The original could not be read under the existing authority. */
    UNAVAILABLE,

    /** This route has no workspace/provider original (run-output or local copy). */
    NOT_APPLICABLE,
}

/** Deliberate conflict decisions offered after both versions are observed. */
enum class OfficeConflictReviewAction {
    /** Do not write the original. The working copy stays retained. */
    KEEP_CURRENT,

    /** Export the working copy through the existing verified Save-Copy path. */
    PRESERVE_MINE_AS_COPY,

    /**
     * Re-read the live original and retry the ORIGINAL write only through an
     * existing compare-and-swap authority. The manual viewer has no such
     * authority, so production answers `originalCasUnavailable`; this is a
     * truthful refusal, never a hidden overwrite.
     */
    RETRY_ORIGINAL_CAS,
}

/**
 * Bounded facts about the two immutable versions. No paths, URIs, document
 * text or credentials cross this channel; the App keeps the actual snapshots.
 */
data class OfficeConflictReviewAnswer(
    val state: OfficeConflictReviewState,
    val recordId: String?,
    val baseSha256: String?,
    val baseRevision: String?,
    val mineSha256: String?,
    val mineBytes: Long,
    val currentSha256: String?,
    val currentBytes: Long,
    val currentRevision: String?,
    val canKeepCurrent: Boolean,
    val canPreserveMineAsCopy: Boolean,
    val canRetryOriginalCas: Boolean,
    val reason: String?,
) {
    fun descriptorLine(): String = listOf(
        state.name,
        recordId ?: "-",
        baseSha256 ?: "-",
        baseRevision ?: "-",
        mineSha256 ?: "-",
        mineBytes.toString(),
        currentSha256 ?: "-",
        currentBytes.toString(),
        currentRevision ?: "-",
        if (canKeepCurrent) "1" else "0",
        if (canPreserveMineAsCopy) "1" else "0",
        if (canRetryOriginalCas) "1" else "0",
        reason ?: "-",
    ).joinToString("|")

    companion object {
        fun fromDescriptorLine(line: String): OfficeConflictReviewAnswer? {
            val fields = line.split('|')
            if (fields.size != 13) return null
            val state = runCatching { OfficeConflictReviewState.valueOf(fields[0]) }.getOrNull() ?: return null
            fun text(index: Int, max: Int = 160): String? =
                fields[index].takeIf { it != "-" }?.takeIf { it.length <= max && it.none { c -> c == '\n' || c == '\r' } }
            fun sha(index: Int): String? = text(index, 64)?.lowercase(Locale.ROOT)
                ?.takeIf { it.matches(Regex("^[0-9a-f]{64}$")) }
            val mineBytes = fields[5].toLongOrNull()?.takeIf { it >= 0L } ?: return null
            val currentBytes = fields[7].toLongOrNull()?.takeIf { it >= 0L } ?: return null
            fun flag(index: Int): Boolean = fields[index] == "1"
            return OfficeConflictReviewAnswer(
                state = state,
                recordId = text(1, 128),
                baseSha256 = sha(2),
                baseRevision = text(3),
                mineSha256 = sha(4),
                mineBytes = mineBytes,
                currentSha256 = sha(6),
                currentBytes = currentBytes,
                currentRevision = text(8),
                canKeepCurrent = flag(9),
                canPreserveMineAsCopy = flag(10),
                canRetryOriginalCas = flag(11),
                reason = text(12),
            )
        }
    }
}

/** Result of one deliberate conflict decision (admission only, never a write claim). */
data class OfficeConflictResolutionResult(
    val accepted: Boolean,
    val code: String,
    val detail: String?,
) {
    fun descriptorLine(): String = listOf(
        if (accepted) "1" else "0",
        code.take(64),
        detail?.take(240) ?: "-",
    ).joinToString("|")

    companion object {
        fun fromDescriptorLine(line: String): OfficeConflictResolutionResult? {
            val fields = line.split('|')
            if (fields.size != 3) return null
            if (fields[0] != "1" && fields[0] != "0") return null
            val code = fields[1].takeIf { it.isNotEmpty() && it.length <= 64 } ?: return null
            val detail = fields[2].takeIf { it != "-" && it.length <= 240 }
            return OfficeConflictResolutionResult(fields[0] == "1", code, detail)
        }
    }
}

/** Which retained version the viewer is asking to inspect. */
enum class OfficeConflictPreviewRole {
    MINE,
    CURRENT,
}

/**
 * Bounded receipt for one retained-snapshot preview.
 *
 * The descriptor carries NO document text and NO absolute path. It names the
 * exact opaque review record/role, both source digests/sizes and an App-owned
 * review-directory-relative text file. The viewer re-proves containment and
 * both digests before showing anything. [leaseId] keeps the App-owned review
 * directory alive until the viewer closes that preview; cleanup waits for
 * every lease to drain.
 */
data class OfficeConflictPreviewAnswer(
    val ready: Boolean,
    val recordId: String?,
    val role: OfficeConflictPreviewRole?,
    val snapshotSha256: String?,
    val snapshotBytes: Long,
    val relativePath: String?,
    val previewSha256: String?,
    val previewBytes: Long,
    val truncated: Boolean,
    val leaseId: String?,
    val reason: String?,
) {
    /** True only for the exact record/role/source digest the viewer asked for. */
    fun matches(recordId: String, role: OfficeConflictPreviewRole, snapshotSha256: String): Boolean =
        ready &&
            this.recordId == recordId &&
            this.role == role &&
            this.snapshotSha256?.equals(snapshotSha256, ignoreCase = true) == true &&
            this.relativePath != null &&
            this.previewSha256 != null &&
            this.leaseId != null

    companion object {
        /** Bounded plain-text projection; never the whole document. */
        const val MAX_TEXT_CHARS = 12_000

        /** Bounded derived text file; the snapshot itself stays untouched. */
        const val MAX_PREVIEW_FILE_BYTES = 64L * 1024L

        const val MAX_LEASE_ID = 64

        fun refused(
            reason: String,
            recordId: String? = null,
            role: OfficeConflictPreviewRole? = null,
            snapshotSha256: String? = null,
            snapshotBytes: Long = 0L,
        ): OfficeConflictPreviewAnswer = OfficeConflictPreviewAnswer(
            ready = false,
            recordId = recordId,
            role = role,
            snapshotSha256 = snapshotSha256?.takeIf { OfficeConflictPreviewNaming.isSha256(it) },
            snapshotBytes = snapshotBytes.coerceAtLeast(0L),
            relativePath = null,
            previewSha256 = null,
            previewBytes = 0L,
            truncated = false,
            leaseId = null,
            reason = reason.take(64),
        )
    }
}

/** Fixed naming and shape rules shared by the App producer and viewer. */
object OfficeConflictPreviewNaming {
    /** App-owned review root below noBackupFilesDir; shared by both processes. */
    const val REVIEW_ROOT = "floe-office-reviews"

    const val MINE_FILE = "mine.preview"
    const val CURRENT_FILE = "current.preview"

    private val REVIEW_DIRECTORY = Regex("^review-[A-Za-z0-9-]{8,64}$")
    private val SHA256 = Regex("^[0-9a-f]{64}$")
    private val LEASE = Regex("^[A-Za-z0-9_-]{1,64}$")

    fun fileName(role: OfficeConflictPreviewRole): String = when (role) {
        OfficeConflictPreviewRole.MINE -> MINE_FILE
        OfficeConflictPreviewRole.CURRENT -> CURRENT_FILE
    }

    fun isReviewDirectoryName(value: String): Boolean = REVIEW_DIRECTORY.matches(value)

    /** App-owned receipt path: one bounded review directory + fixed leaf. */
    fun relativePath(directoryName: String, role: OfficeConflictPreviewRole): String? =
        directoryName.takeIf { isReviewDirectoryName(it) }?.let { "$it/${fileName(role)}" }

    /** Exactly one review directory component and the role's fixed leaf. */
    fun isValidRelativePath(value: String, role: OfficeConflictPreviewRole): Boolean {
        val parts = value.split('/')
        return parts.size == 2 &&
            isReviewDirectoryName(parts[0]) &&
            parts[1] == fileName(role)
    }

    fun isSha256(value: String?): Boolean = value != null && SHA256.matches(value)

    fun isLeaseId(value: String?): Boolean = value != null && LEASE.matches(value)
}

/** The App-side implementation the viewer channel binds to. */
interface OfficeConflictReviewHandler {
    fun review(sessionToken: String, generation: Long, requestId: String): OfficeConflictReviewAnswer

    fun resolve(
        sessionToken: String,
        generation: Long,
        recordId: String,
        action: OfficeConflictReviewAction,
    ): OfficeConflictResolutionResult

    fun release(sessionToken: String, generation: Long, recordId: String?)

    /**
     * Prepares one bounded text projection of the exact retained version and
     * returns an App-owned receipt plus a cleanup lease. Implementations must
     * re-prove the live owner/generation and the retained digest first.
     */
    fun preview(
        sessionToken: String,
        generation: Long,
        recordId: String,
        role: OfficeConflictPreviewRole,
        expectedSha256: String,
    ): OfficeConflictPreviewAnswer

    /** Viewer finished reading the preview; the lease may now drain. */
    fun releasePreview(sessionToken: String, generation: Long, leaseId: String)
}

/**
 * Same-UID, non-exported review channel between the foreground viewer and the
 * App-owned Office controller.
 *
 * The viewer only asks for observed version facts and makes a deliberate
 * decision; the App performs every file/provider/workspace read and keeps the
 * immutable snapshots. The request carries the exact session token, native
 * mount generation and a viewer-minted request id. Every reply is fenced by
 * the App-side record; a stale viewer can never resolve a newer document.
 */
object OfficeConflictReviewChannel {
    const val EXTRA_REVIEW_CHANNEL = "com.floe.android.office.ORIGINAL_REVIEW_CHANNEL"
    const val DESCRIPTOR = "com.floe.android.core.officeengine.OriginalReview"

    const val TRANSACTION_REVIEW = 1
    const val TRANSACTION_RESOLVE = 2
    const val TRANSACTION_RELEASE = 3
    const val TRANSACTION_PREVIEW = 4
    const val TRANSACTION_RELEASE_PREVIEW = 5

    private const val MAX_TOKEN = 128
    private const val MAX_REPLY = 4096

    fun parentBinder(handler: OfficeConflictReviewHandler): IBinder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(DESCRIPTOR)
                return true
            }
            if (Binder.getCallingUid() != Process.myUid()) return false
            return when (code) {
                TRANSACTION_REVIEW -> {
                    data.enforceInterface(DESCRIPTOR)
                    val token = data.readString().orEmpty()
                    val generation = data.readLong()
                    val requestId = data.readString().orEmpty()
                    if (!validToken(token) || generation <= 0L ||
                        !requestId.matches(Regex("^[A-Za-z0-9_-]{1,64}$"))
                    ) return false
                    val answer = handler.review(token, generation, requestId)
                    reply?.writeNoException()
                    reply?.writeString(answer.descriptorLine())
                    true
                }
                TRANSACTION_RESOLVE -> {
                    data.enforceInterface(DESCRIPTOR)
                    val token = data.readString().orEmpty()
                    val generation = data.readLong()
                    val recordId = data.readString().orEmpty()
                    val actionName = data.readString().orEmpty()
                    val action = runCatching { OfficeConflictReviewAction.valueOf(actionName) }.getOrNull()
                        ?: return false
                    if (!validToken(token) || generation <= 0L || !validRecord(recordId)) return false
                    val result = handler.resolve(token, generation, recordId, action)
                    reply?.writeNoException()
                    reply?.writeString(result.descriptorLine())
                    true
                }
                TRANSACTION_RELEASE -> {
                    data.enforceInterface(DESCRIPTOR)
                    val token = data.readString().orEmpty()
                    val generation = data.readLong()
                    val recordId = data.readString().orEmpty().takeIf { it != "-" }
                    if (!validToken(token) || generation <= 0L ||
                        (recordId != null && !validRecord(recordId))
                    ) return false
                    handler.release(token, generation, recordId)
                    reply?.writeNoException()
                    reply?.writeInt(1)
                    true
                }
                TRANSACTION_PREVIEW -> {
                    data.enforceInterface(DESCRIPTOR)
                    val token = data.readString().orEmpty()
                    val generation = data.readLong()
                    val recordId = data.readString().orEmpty()
                    val roleName = data.readString().orEmpty()
                    val expectedSha256 = data.readString().orEmpty()
                    val role = runCatching { OfficeConflictPreviewRole.valueOf(roleName) }.getOrNull()
                        ?: return false
                    if (!validToken(token) || generation <= 0L || !validRecord(recordId) ||
                        !OfficeConflictPreviewNaming.isSha256(expectedSha256)
                    ) return false
                    val answer = runCatching {
                        handler.preview(token, generation, recordId, role, expectedSha256)
                    }.getOrElse {
                        OfficeConflictPreviewAnswer.refused(
                            reason = "previewFailed",
                            recordId = recordId,
                            role = role,
                            snapshotSha256 = expectedSha256,
                        )
                    }
                    writePreviewReply(reply, answer)
                    true
                }
                TRANSACTION_RELEASE_PREVIEW -> {
                    data.enforceInterface(DESCRIPTOR)
                    val token = data.readString().orEmpty()
                    val generation = data.readLong()
                    val leaseId = data.readString().orEmpty()
                    if (!validToken(token) || generation <= 0L ||
                        !OfficeConflictPreviewNaming.isLeaseId(leaseId)
                    ) return false
                    handler.releasePreview(token, generation, leaseId)
                    reply?.writeNoException()
                    reply?.writeInt(1)
                    true
                }
                else -> super.onTransact(code, data, reply, flags)
            }
        }
    }

    /** Viewer → App. May block on bounded provider/workspace IO; call off main. */
    fun review(binder: IBinder?, sessionToken: String, generation: Long, requestId: String): OfficeConflictReviewAnswer? {
        if (binder == null || !validToken(sessionToken) || generation <= 0L ||
            !requestId.matches(Regex("^[A-Za-z0-9_-]{1,64}$"))
        ) return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeString(requestId)
            if (!binder.transact(TRANSACTION_REVIEW, data, reply, 0)) return null
            reply.readException()
            val line = reply.readString() ?: return null
            if (line.length > MAX_REPLY) null else OfficeConflictReviewAnswer.fromDescriptorLine(line)
        } catch (_: Exception) {
            null
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Viewer → App deliberate decision. */
    fun resolve(
        binder: IBinder?,
        sessionToken: String,
        generation: Long,
        recordId: String,
        action: OfficeConflictReviewAction,
    ): OfficeConflictResolutionResult? {
        if (binder == null || !validToken(sessionToken) || generation <= 0L || !validRecord(recordId)) return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeString(recordId)
            data.writeString(action.name)
            if (!binder.transact(TRANSACTION_RESOLVE, data, reply, 0)) return null
            reply.readException()
            val line = reply.readString() ?: return null
            if (line.length > MAX_REPLY) null else OfficeConflictResolutionResult.fromDescriptorLine(line)
        } catch (_: Exception) {
            null
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Viewer → App: drop only this review's temporary snapshots. */
    fun release(binder: IBinder?, sessionToken: String, generation: Long, recordId: String?): Boolean {
        if (binder == null || !validToken(sessionToken) || generation <= 0L) return false
        if (recordId != null && !validRecord(recordId)) return false
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeString(recordId ?: "-")
            if (!binder.transact(TRANSACTION_RELEASE, data, reply, 0)) return false
            reply.readException()
            reply.readInt() == 1
        } catch (_: Exception) {
            false
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /**
     * Viewer → App: prepare one bounded text projection of the exact
     * retained version. May block on a bounded App-side package read; call
     * off main. A ready answer is a receipt + lease, never document text.
     */
    fun preview(
        binder: IBinder?,
        sessionToken: String,
        generation: Long,
        recordId: String,
        role: OfficeConflictPreviewRole,
        expectedSha256: String,
    ): OfficeConflictPreviewAnswer? {
        if (binder == null || !validToken(sessionToken) || generation <= 0L ||
            !validRecord(recordId) || !OfficeConflictPreviewNaming.isSha256(expectedSha256)
        ) return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeString(recordId)
            data.writeString(role.name)
            data.writeString(expectedSha256)
            if (!binder.transact(TRANSACTION_PREVIEW, data, reply, 0)) return null
            reply.readException()
            val ready = reply.readInt() == 1
            val answerRecordId = reply.readString()?.takeIf { it != "-" }
            val roleName = reply.readString()?.takeIf { it != "-" }
            val snapshotSha = reply.readString()?.takeIf { it != "-" }
            val snapshotBytes = reply.readLong()
            val relativePath = reply.readString()?.takeIf { it != "-" }
            val previewSha = reply.readString()?.takeIf { it != "-" }
            val previewBytes = reply.readLong()
            val truncated = reply.readInt() == 1
            val leaseId = reply.readString()?.takeIf { it != "-" }
            val reason = reply.readString()?.takeIf { it != "-" }
            val answerRole = roleName?.let {
                runCatching { OfficeConflictPreviewRole.valueOf(it) }.getOrNull()
            }
            val answer = OfficeConflictPreviewAnswer(
                ready = ready,
                recordId = answerRecordId?.takeIf { validRecord(it) },
                role = answerRole,
                snapshotSha256 = snapshotSha?.takeIf { OfficeConflictPreviewNaming.isSha256(it) },
                snapshotBytes = snapshotBytes.coerceAtLeast(0L),
                relativePath = relativePath,
                previewSha256 = previewSha?.takeIf { OfficeConflictPreviewNaming.isSha256(it) },
                previewBytes = previewBytes.coerceAtLeast(0L),
                truncated = truncated,
                leaseId = leaseId,
                reason = reason?.takeIf { it.length <= 64 },
            )
            if (ready) {
                if (!answer.matches(recordId, role, expectedSha256)) return null
                if (answer.snapshotBytes <= 0L) return null
                if (!OfficeConflictPreviewNaming.isValidRelativePath(
                        answer.relativePath.orEmpty(),
                        role,
                    )
                ) return null
                if (answer.previewBytes !in 1L..OfficeConflictPreviewAnswer.MAX_PREVIEW_FILE_BYTES) return null
                if (!OfficeConflictPreviewNaming.isLeaseId(answer.leaseId)) return null
            } else {
                if (answer.reason.isNullOrEmpty()) return null
                if (answer.relativePath != null || answer.previewSha256 != null ||
                    answer.leaseId != null
                ) return null
            }
            answer
        } catch (_: Exception) {
            null
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Viewer → App: this preview is closed; the cleanup lease may drain. */
    fun releasePreview(
        binder: IBinder?,
        sessionToken: String,
        generation: Long,
        leaseId: String,
    ): Boolean {
        if (binder == null || !validToken(sessionToken) || generation <= 0L ||
            !OfficeConflictPreviewNaming.isLeaseId(leaseId)
        ) return false
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeString(leaseId)
            if (!binder.transact(TRANSACTION_RELEASE_PREVIEW, data, reply, 0)) return false
            reply.readException()
            reply.readInt() == 1
        } catch (_: Exception) {
            false
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    private fun writePreviewReply(reply: Parcel?, answer: OfficeConflictPreviewAnswer) {
        reply?.writeNoException()
        reply?.writeInt(if (answer.ready) 1 else 0)
        reply?.writeString(answer.recordId ?: "-")
        reply?.writeString(answer.role?.name ?: "-")
        reply?.writeString(answer.snapshotSha256 ?: "-")
        reply?.writeLong(answer.snapshotBytes)
        reply?.writeString(answer.relativePath ?: "-")
        reply?.writeString(answer.previewSha256 ?: "-")
        reply?.writeLong(answer.previewBytes)
        reply?.writeInt(if (answer.truncated) 1 else 0)
        reply?.writeString(answer.leaseId ?: "-")
        reply?.writeString(answer.reason ?: "-")
    }

    private fun validToken(value: String): Boolean =
        value.isNotBlank() && value.length <= MAX_TOKEN && value.none { it.code < 0x20 || it == '/' || it == '\\' }

    private fun validRecord(value: String): Boolean =
        value.matches(Regex("^[A-Za-z0-9_-]{1,64}$"))
}
