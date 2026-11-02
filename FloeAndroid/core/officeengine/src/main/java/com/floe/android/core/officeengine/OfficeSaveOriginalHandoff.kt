// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process

/**
 * Pure shape rules for the manual workspace "Save Original" handoff
 * (OFC-SAVE-REOPEN manual original-save closure). The module NEVER touches
 * the workspace store, a CAS authority, a provider journal or any file write
 * as an authorizer: the visible "Save Original" action performs ONE real
 * `WORKING_COPY_FLUSH` (`.uno:Save`) on the App-owned working copy, then
 * posts the just-verified working-copy digest/byte count to the App
 * capability. The App alone re-reads and re-digests its OWN working copy,
 * proves the exact owned operation + live owner + engine generation, runs
 * the EXISTING native workspace CAS through the trusted source-host lane and
 * answers with one bounded verdict. Nothing crossing this boundary is a
 * path, URI, document text or model claim.
 *
 * This mirrors the reviewed [OfficeHostSaveHandoffPolicy] trust model
 * exactly: the capability travels ONLY inside the non-exported viewer
 * Activity's own launch Intent, every transaction re-checks the interface
 * descriptor and the same-application calling UID, and every payload passes
 * the pure shape rules below. A refusal keeps the editor open with the
 * working copy retained; the module never retries silently and never
 * reports "saved" before the App's positive answer.
 */
object OfficeSaveOriginalHandoffPolicy {

    const val DESCRIPTOR = "com.floe.android.core.officeengine.SaveOriginal"

    /** Engine→App: one completed original-save flush for the exact op. */
    const val TRANSACTION_SAVE_ORIGINAL = 1

    /**
     * Viewer launch-Intent extra: this mount's App host owns the workspace
     * original commit and explicitly supports [TRANSACTION_SAVE_ORIGINAL].
     * Present ONLY for EDIT mounts of ordinary task-owned workspace
     * documents (never provider-picked, run-output, read-only, recovery or
     * Notes mounts — those stay copy-only with truthful controls).
     */
    const val EXTRA_SAVE_ORIGINAL = "com.floe.android.office.SAVE_ORIGINAL"

    /** The same-UID, non-exported capability binder on the launch Intent. */
    const val EXTRA_SAVE_ORIGINAL_CHANNEL = "com.floe.android.office.SAVE_ORIGINAL_CHANNEL"

    /**
     * Verdict space (mirrors the internal-save shape so the module's close
     * logic stays symmetric). [SAVE_ORIGINAL_ACCEPTED] /
     * [SAVE_ORIGINAL_UNCHANGED] describe a FULLY synced action (or one with
     * no provider binding) and authorize the viewer's armed close;
     * [SAVE_ORIGINAL_REJECTED] is also the App's honest answer when the live
     * original no longer matches the open-time baseline (a real conflict):
     * the editor stays open, the working copy is retained and the existing
     * original-version review decides. [SAVE_ORIGINAL_REFUSED] is the
     * transport/fence/shape answer and never claims anything was written.
     *
     * The four SOURCE_* verdicts correlate an attached provider binding for
     * ONE explicit save action: the LOCAL workspace original is proven saved
     * (or already current), but the existing journaled provider ladder did
     * not answer "ok" — PENDING = honestly pending / unavailable /
     * permission / unknown (the journal row carries the recovery identity),
     * CONFLICT = the provider side carries a conflicting version. These
     * verdicts NEVER authorize the armed close: the editor stays open with
     * everything retained and an actionable notice, so a local-saved /
     * source-pending result can never close as if fully synced.
     */
    const val SAVE_ORIGINAL_ACCEPTED = 1
    const val SAVE_ORIGINAL_UNCHANGED = 2
    const val SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING = 3
    const val SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING = 4
    const val SAVE_ORIGINAL_ACCEPTED_SOURCE_CONFLICT = 5
    const val SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT = 6
    const val SAVE_ORIGINAL_REJECTED = -1
    const val SAVE_ORIGINAL_REFUSED = 0

    /** Notice parcel schema version (first field). */
    const val SCHEMA_VERSION = 1

    /**
     * One completed original-save flush: the op identity plus the exact
     * working-copy facts the engine re-read after its real `.uno:Save` ack.
     * No path crosses this boundary: the App already owns the working copy
     * and re-verifies it against these facts before any commit is attempted.
     */
    data class SaveOriginalNotice(
        val opId: String,
        val sessionToken: String,
        val generation: Long,
        val format: String,
        val workingCopySha256: String,
        val workingCopyBytes: Long,
    )

    private val OP_ID_REGEX = Regex("^[A-Za-z0-9_-]{1,64}$")
    private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")

    /** The only working-copy formats an original commit may carry. */
    val SAVE_ORIGINAL_FORMATS: Set<String> = setOf("docx", "xlsx", "pptx")

    fun validOpId(opId: String?): Boolean =
        opId != null && OP_ID_REGEX.matches(opId)

    fun validToken(token: String?): Boolean =
        !token.isNullOrEmpty() && token.length <= OfficeCloseAckPolicy.MAX_TOKEN_CHARS &&
            token.none { it.code < 0x20 || it.code == 0x7f }

    fun validFormat(format: String?): Boolean =
        format != null && format in SAVE_ORIGINAL_FORMATS

    fun validateSaveOriginal(
        opId: String?,
        token: String?,
        generation: Long?,
        format: String?,
        workingCopySha256: String?,
        workingCopyBytes: Long?,
    ): SaveOriginalNotice? = when {
        !validOpId(opId) || !validToken(token) || generation == null || generation < 1L -> null
        !validFormat(format) -> null
        workingCopySha256 == null || !SHA256_REGEX.matches(workingCopySha256) -> null
        workingCopyBytes == null || workingCopyBytes < 1L ||
            workingCopyBytes > OfficeRequestPolicy.MAX_STAGED_BYTES -> null
        else -> SaveOriginalNotice(
            opId = opId!!,
            sessionToken = token!!,
            generation = generation,
            format = format!!,
            workingCopySha256 = workingCopySha256,
            workingCopyBytes = workingCopyBytes,
        )
    }

    /**
     * Maps ONE terminal save receipt to a handoff notice. ONLY a real
     * FLUSHED/UNMODIFIED receipt with verified working-copy facts yields a
     * notice; every other terminal (OUTPUT_READY is the Save-Copy lane,
     * FAILED/UNKNOWN/CANCELLED/REJECTED) maps to null so the caller keeps its
     * honest failure/unknown path — never a silent save-original attempt.
     *
     * [mountFormat] is THIS mount's own preview-request format (the flush
     * receipt itself carries no format — see [OfficeSaveReceipt.format]).
     * Pure and JVM-testable; the viewer applies it on the main thread only.
     */
    fun noticeFromReceipt(receipt: OfficeSaveReceipt, mountFormat: String?): SaveOriginalNotice? {
        if (receipt.operation != OfficeSaveOperation.WORKING_COPY_FLUSH) return null
        if (receipt.state != OfficeSaveState.FLUSHED && receipt.state != OfficeSaveState.UNMODIFIED) {
            return null
        }
        return validateSaveOriginal(
            opId = receipt.opId,
            token = receipt.sessionToken,
            generation = receipt.generation,
            format = mountFormat,
            workingCopySha256 = receipt.workingCopySha256,
            workingCopyBytes = receipt.workingCopyBytes,
        )
    }
}

/**
 * Binder transport for [OfficeSaveOriginalHandoffPolicy], byte-mirroring the
 * fail-closed [OfficeHostSaveChannel] pattern: the parent endpoint travels
 * ONLY inside the non-exported viewer Activity's own launch Intent, so the
 * only processes that can hold it are this same application's processes;
 * every transaction re-checks the interface descriptor and the
 * same-application calling UID, and the payload passes the pure shape rules.
 * Any transport problem is the plain [SAVE_ORIGINAL_REFUSED] verdict — the
 * viewer then keeps the editor open with an honest notice and never fakes a
 * completed original save.
 */
object OfficeSaveOriginalChannel {

    /**
     * App(parent)-side endpoint factory. [onSaveOriginal] runs on a Binder
     * thread (the viewer posts from ONE dedicated background thread, exactly
     * like the internal-save handoff) and must return one of the
     * [OfficeSaveOriginalHandoffPolicy] verdicts. The App re-reads/digests
     * its own working copy and runs the real commit before answering; a
     * throwing handler is mapped to [SAVE_ORIGINAL_REJECTED] so the editor
     * stays open — never a false positive.
     */
    @JvmStatic
    fun parentBinder(
        onSaveOriginal: (OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice) -> Int,
    ): IBinder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != OfficeSaveOriginalHandoffPolicy.TRANSACTION_SAVE_ORIGINAL) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(OfficeSaveOriginalHandoffPolicy.DESCRIPTOR)
            val sameUid = Binder.getCallingUid() == Process.myUid()
            if (!sameUid) {
                reply?.writeNoException()
                reply?.writeInt(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED)
                return true
            }
            val notice = readNotice(data)
            // Fail closed: no notice, a throwing handler or an out-of-range
            // verdict keeps the editor open with the working copy retained.
            val answer = if (notice == null) {
                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
            } else {
                runCatching { onSaveOriginal(notice) }
                    .getOrDefault(OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED)
                    .takeIf {
                        it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED ||
                            it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED ||
                            it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING ||
                            it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING ||
                            it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_CONFLICT ||
                            it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT ||
                            it == OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
                    }
                    ?: OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
            }
            reply?.writeNoException()
            reply?.writeInt(answer)
            return true
        }
    }

    /**
     * Engine→App: pushes one verified original-save notice. The reply is one
     * bounded verdict int; any transport/shape problem is
     * [SAVE_ORIGINAL_REFUSED] and the caller keeps the editor open.
     */
    @JvmStatic
    fun postSaveOriginal(
        channel: IBinder?,
        notice: OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice,
    ): Int {
        if (channel == null || !channel.pingBinder()) {
            return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
        }
        if (OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                notice.opId,
                notice.sessionToken,
                notice.generation,
                notice.format,
                notice.workingCopySha256,
                notice.workingCopyBytes,
            ) == null
        ) return OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeSaveOriginalHandoffPolicy.DESCRIPTOR)
            writeNotice(data, notice)
            val transacted = channel.transact(
                OfficeSaveOriginalHandoffPolicy.TRANSACTION_SAVE_ORIGINAL,
                data,
                reply,
                0,
            )
            if (transacted) {
                reply.readException()
                reply.readInt()
            } else {
                OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
            }
        } catch (e: Exception) {
            OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    // ------------------------------------------------------------------
    // Flat, versioned marshalling (fixed field order; never a Java-serialized object graph)
    // ------------------------------------------------------------------

    private fun writeNotice(parcel: Parcel, notice: OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice) {
        parcel.writeInt(OfficeSaveOriginalHandoffPolicy.SCHEMA_VERSION)
        parcel.writeString(notice.opId)
        parcel.writeString(notice.sessionToken)
        parcel.writeLong(notice.generation)
        parcel.writeString(notice.format)
        parcel.writeString(notice.workingCopySha256)
        parcel.writeLong(notice.workingCopyBytes)
    }

    /** Single ordered reader; field order must match [writeNotice] exactly. */
    private fun readNotice(parcel: Parcel): OfficeSaveOriginalHandoffPolicy.SaveOriginalNotice? {
        return try {
            if (parcel.readInt() != OfficeSaveOriginalHandoffPolicy.SCHEMA_VERSION) return null
            OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                opId = parcel.readString(),
                token = parcel.readString(),
                generation = parcel.readLong(),
                format = parcel.readString(),
                workingCopySha256 = parcel.readString(),
                workingCopyBytes = parcel.readLong(),
            )
        } catch (e: Exception) {
            null
        }
    }
}
