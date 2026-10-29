// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process

/**
 * Pure shape rules for the generic host save-target handoff (Main decision
 * 2026-10-26). The module NEVER touches SAF, grants, URIs or pickers as an
 * authorizer: the App host prepares the CREATE_DOCUMENT (or equivalent)
 * Intent, the module's FOREGROUND viewer Activity launches it through
 * StartActivityForResult (the background App process must not assume
 * background-activity-launch permission), and the module forwards the
 * ACTUAL result URI string + ACTUAL returned intent flags + the exact
 * op/session identity back to the App capability, which alone runs
 * SafGateway acceptance, IO, readback and final acknowledgement.
 *
 * Everything crossing this boundary is inert data: an opaque op id, the
 * session identity, a format token, a suggested display name, a result code,
 * a URI string, platform flag bits and (for the internal Notes destination)
 * the exact post-flush working-copy digest/byte count. The module does not
 * resolve, grant, persist or interpret any of it. The internal transaction
 * carries NO path or URI: the App re-verifies its own working copy.
 */
object OfficeHostSaveHandoffPolicy {

    const val DESCRIPTOR = "com.floe.android.core.officeengine.HostSave"

    /** Engine→App: give me the prepared save-target picker Intent for this exact op. */
    const val TRANSACTION_PREPARE_TARGET = 2

    /** Engine→App: here is the ACTUAL picker result (uri + flags + resultCode) for this exact op. */
    const val TRANSACTION_DELIVER_PICK_RESULT = 3

    /** Engine→App: one typed save receipt (also delivered in-process via the listener). */
    const val TRANSACTION_SAVE_RECEIPT = 4

    /** Engine→App: live edit/dirty/undo state snapshot for the exact mount. */
    const val TRANSACTION_EDIT_STATE = 5

    /**
     * Engine→App (R3 internal-notes save): one explicit "save and return"
     * flush completed for the exact op, with the just-verified working-copy
     * digest that THIS App-owned working copy must still match. The App
     * snapshots and verifies the bytes before answering, exactly like the
     * external COPY_SAVED settlement; the engine closes only after the
     * answer. This is a destination handoff for an App-owned internal
     * output — never a user/provider URI and never a "saved to Notes" claim
     * by the module. It is used only for mounts whose launch Intent carries
     * [EXTRA_INTERNAL_SAVE]; the generic SAF Save-Copy path is unchanged.
     */
    const val TRANSACTION_INTERNAL_SAVE = 6

    /**
     * Viewer launch-Intent extra: this mount's App host owns an internal
     * working-copy commit and explicitly supports
     * [TRANSACTION_INTERNAL_SAVE]. With it, an edited document's dirty
     * close sheet offers "Save and close" (no system file picker) and the
     * ordinary "Save Copy" menu remains the optional external export.
     */
    const val EXTRA_INTERNAL_SAVE = "com.floe.android.office.INTERNAL_SAVE"

    /** Receipt/edit-state/internal-save parcel schema version (first field). */
    const val SCHEMA_VERSION = 1

    /**
     * Internal-save replies. Positive answers authorize the viewer to close
     * (the App either snapshotted new bytes or proved the working copy still
     * equals the base). A typed negative answer keeps the editor open with
     * the working copy retained; [INTERNAL_SAVE_REFUSED] is also the
     * transport/missing-channel answer.
     */
    const val INTERNAL_SAVE_ACCEPTED = 1
    const val INTERNAL_SAVE_UNCHANGED = 2
    const val INTERNAL_SAVE_REJECTED = -1
    const val INTERNAL_SAVE_REFUSED = 0

    const val MAX_OP_ID_CHARS = 64
    const val MAX_URI_CHARS = 4096
    const val MAX_NAME_CHARS = 240

    /** One prepare request, shape-validated. */
    data class PrepareRequest(
        val opId: String,
        val sessionToken: String,
        val generation: Long,
        val format: String,
        val suggestedName: String?,
    )

    /** One actual picker result, shape-validated. The URI string stays inert. */
    data class PickResult(
        val opId: String,
        val sessionToken: String,
        val generation: Long,
        val resultCode: Int,
        val uriString: String?,
        val resultFlags: Int,
    )

    /**
     * One completed internal-save flush: the op identity plus the exact
     * working-copy facts the engine re-read after its real `.uno:Save` ack.
     * No path crosses this boundary: the App already owns the working copy
     * and re-verifies it against these facts before importing anything.
     */
    data class InternalSaveNotice(
        val opId: String,
        val sessionToken: String,
        val generation: Long,
        val format: String,
        val workingCopySha256: String,
        val workingCopyBytes: Long,
    )

    private val OP_ID_REGEX = Regex("^[A-Za-z0-9_-]{1,64}$")
    private val SHA256_REGEX = Regex("^[0-9a-f]{64}$")

    /** The only working-copy formats an internal Notes commit may carry. */
    val INTERNAL_SAVE_FORMATS: Set<String> = setOf("docx", "xlsx", "pptx")

    fun validOpId(opId: String?): Boolean =
        opId != null && OP_ID_REGEX.matches(opId)

    fun validToken(token: String?): Boolean =
        !token.isNullOrEmpty() && token.length <= OfficeCloseAckPolicy.MAX_TOKEN_CHARS &&
            token.none { it.code < 0x20 || it.code == 0x7f }

    fun validFormat(format: String?): Boolean =
        format != null && format in OfficeRequestPolicy.EXPORT_FORMATS

    fun validSuggestedName(name: String?): Boolean =
        name == null || (name.isNotBlank() && name.length <= MAX_NAME_CHARS &&
            !name.contains('/') && !name.contains('\\') && !name.contains('\u0000') &&
            !name.contains('|'))

    fun validUriString(uri: String?): Boolean =
        uri == null || (uri.length in 1..MAX_URI_CHARS && uri.none { it.code < 0x20 || it.code == 0x7f })

    fun validatePrepare(
        opId: String?, token: String?, generation: Long?, format: String?, suggestedName: String?,
    ): PrepareRequest? = when {
        !validOpId(opId) || !validToken(token) || generation == null || generation < 1L -> null
        !validFormat(format) || !validSuggestedName(suggestedName) -> null
        else -> PrepareRequest(opId!!, token!!, generation, format!!, suggestedName)
    }

    fun validatePickResult(
        opId: String?, token: String?, generation: Long?, resultCode: Int?, uriString: String?, flags: Int?,
    ): PickResult? = when {
        !validOpId(opId) || !validToken(token) || generation == null || generation < 1L -> null
        resultCode == null || flags == null -> null
        !validUriString(uriString) -> null
        else -> PickResult(opId!!, token!!, generation, resultCode, uriString, flags)
    }

    fun validateInternalSave(
        opId: String?,
        token: String?,
        generation: Long?,
        format: String?,
        workingCopySha256: String?,
        workingCopyBytes: Long?,
    ): InternalSaveNotice? = when {
        !validOpId(opId) || !validToken(token) || generation == null || generation < 1L -> null
        format == null || format !in INTERNAL_SAVE_FORMATS -> null
        workingCopySha256 == null || !SHA256_REGEX.matches(workingCopySha256) -> null
        workingCopyBytes == null || workingCopyBytes < 1L ||
            workingCopyBytes > OfficeRequestPolicy.MAX_STAGED_BYTES -> null
        else -> InternalSaveNotice(
            opId = opId!!,
            sessionToken = token!!,
            generation = generation,
            format = format,
            workingCopySha256 = workingCopySha256,
            workingCopyBytes = workingCopyBytes,
        )
    }
}

/**
 * Binder transport for [OfficeHostSaveHandoffPolicy], mirroring the
 * fail-closed [OfficeCloseAck] pattern: the parent endpoint travels ONLY
 * inside the non-exported viewer Activity's own launch Intent (or the
 * App-side engine bind Intent), so the only processes that can hold it are
 * this same application's processes; every transaction re-checks the
 * interface descriptor and the same-application calling UID, and every
 * payload passes the pure shape rules. Any transport problem is a plain
 * false/null — the engine then surfaces an honest refusal notice and never
 * fakes a completed save-copy handoff.
 */
object OfficeHostSaveChannel {

    /**
     * App(parent)-side endpoint factory.
     *
     * [onPrepare] runs on a Binder thread and must return the prepared picker
     * Intent (pure Intent construction — the App must NOT launch it itself;
     * the module's foreground Activity launches it) or null to refuse.
     * [onPickResult] receives the actual system result for the exact op.
     * [onReceipt]/[onEditState] mirror the in-process listener events for
     * App-stage consumers that drive saving from the default process.
     */
    @JvmStatic
    fun parentBinder(
        onPrepare: (OfficeHostSaveHandoffPolicy.PrepareRequest) -> Intent?,
        onPickResult: (OfficeHostSaveHandoffPolicy.PickResult) -> Boolean,
        onReceipt: (OfficeSaveReceipt) -> Unit = {},
        onEditState: (OfficeEditState) -> Unit = {},
        /**
         * Optional App-owned internal destination. Called synchronously on a
         * Binder thread after a genuine FLUSHED/UNMODIFIED receipt for the
         * exact [OfficeHostSaveHandoffPolicy.InternalSaveNotice]. The App
         * MUST re-read/digest/snapshot its own working copy and return true
         * only after the bytes match; false keeps the editor open.
         */
        onInternalSave: (OfficeHostSaveHandoffPolicy.InternalSaveNotice) -> Int =
            { OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED },
    ): IBinder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in setOf(
                    OfficeHostSaveHandoffPolicy.TRANSACTION_PREPARE_TARGET,
                    OfficeHostSaveHandoffPolicy.TRANSACTION_DELIVER_PICK_RESULT,
                    OfficeHostSaveHandoffPolicy.TRANSACTION_SAVE_RECEIPT,
                    OfficeHostSaveHandoffPolicy.TRANSACTION_EDIT_STATE,
                    OfficeHostSaveHandoffPolicy.TRANSACTION_INTERNAL_SAVE,
                )
            ) {
                return super.onTransact(code, data, reply, flags)
            }
            // Unknown or mismatched interface tokens reject fail-closed.
            data.enforceInterface(OfficeHostSaveHandoffPolicy.DESCRIPTOR)
            val sameUid = Binder.getCallingUid() == Process.myUid()
            if (!sameUid) {
                reply?.writeInt(0)
                return true
            }
            when (code) {
                OfficeHostSaveHandoffPolicy.TRANSACTION_PREPARE_TARGET -> {
                    val request = OfficeHostSaveHandoffPolicy.validatePrepare(
                        opId = data.readString(),
                        token = data.readString(),
                        generation = data.readLong(),
                        format = data.readString(),
                        suggestedName = data.readString(),
                    )
                    val intent = if (request != null) runCatching { onPrepare(request) }.getOrNull() else null
                    reply?.writeInt(if (intent != null) 1 else 0)
                    if (intent != null) reply?.writeParcelable(intent, 0)
                }

                OfficeHostSaveHandoffPolicy.TRANSACTION_DELIVER_PICK_RESULT -> {
                    val result = OfficeHostSaveHandoffPolicy.validatePickResult(
                        opId = data.readString(),
                        token = data.readString(),
                        generation = data.readLong(),
                        resultCode = data.readInt(),
                        uriString = data.readString(),
                        flags = data.readInt(),
                    )
                    val accepted = result != null && runCatching { onPickResult(result) }.getOrDefault(false)
                    reply?.writeInt(if (accepted) 1 else 0)
                }

                OfficeHostSaveHandoffPolicy.TRANSACTION_SAVE_RECEIPT -> {
                    val receipt = readReceipt(data)
                    val accepted = receipt != null && runCatching { onReceipt(receipt) }.let { true }
                    reply?.writeInt(if (accepted) 1 else 0)
                }

                OfficeHostSaveHandoffPolicy.TRANSACTION_EDIT_STATE -> {
                    val state = readEditState(data)
                    if (state != null) runCatching { onEditState(state) }
                    reply?.writeInt(if (state != null) 1 else 0)
                }

                OfficeHostSaveHandoffPolicy.TRANSACTION_INTERNAL_SAVE -> {
                    val notice = readInternalSave(data)
                    // Fail closed: no notice, a throwing verifier or an
                    // explicit refusal keeps the editor open with the
                    // working copy retained. Only the two positive replies
                    // (accepted/unchanged) authorize the close.
                    val answer = if (notice == null) {
                        OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED
                    } else {
                        runCatching { onInternalSave(notice) }
                            .getOrDefault(OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REJECTED)
                            .takeIf {
                                it == OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_ACCEPTED ||
                                    it == OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_UNCHANGED
                            }
                            ?: OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REJECTED
                    }
                    reply?.writeInt(answer)
                }
            }
            return true
        }
    }

    // ------------------------------------------------------------------
    // Engine-side calls (synchronous, fail-closed, never throw)
    // ------------------------------------------------------------------

    /**
     * Asks the App host for the prepared save-target picker Intent for this
     * exact op. Returns null when there is no channel, the host refused, or
     * the transport failed — the caller then surfaces an honest
     * HOST_TARGET_UNAVAILABLE notice; it never launches a self-made picker
     * and never claims the copy was delivered.
     */
    @JvmStatic
    fun requestPrepareTarget(
        channel: IBinder?,
        opId: String,
        sessionToken: String,
        generation: Long,
        format: String,
        suggestedName: String?,
    ): Intent? {
        if (channel == null || !channel.pingBinder()) return null
        if (!OfficeHostSaveHandoffPolicy.validOpId(opId) || !OfficeHostSaveHandoffPolicy.validFormat(format)) return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeHostSaveHandoffPolicy.DESCRIPTOR)
            data.writeString(opId)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeString(format)
            data.writeString(suggestedName)
            val transacted = channel.transact(OfficeHostSaveHandoffPolicy.TRANSACTION_PREPARE_TARGET, data, reply, 0)
            if (!transacted || reply.readInt() != 1) return null
            @Suppress("DEPRECATION")
            reply.readParcelable(Intent::class.java.classLoader) as? Intent
        } catch (e: Exception) {
            null
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Forwards the ACTUAL system picker result for the exact op. False = not acknowledged. */
    @JvmStatic
    fun deliverPickResult(
        channel: IBinder?,
        opId: String,
        sessionToken: String,
        generation: Long,
        resultCode: Int,
        uriString: String?,
        resultFlags: Int,
    ): Boolean {
        if (channel == null || !channel.pingBinder()) return false
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeHostSaveHandoffPolicy.DESCRIPTOR)
            data.writeString(opId)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeInt(resultCode)
            data.writeString(uriString?.takeIf { OfficeHostSaveHandoffPolicy.validUriString(it) })
            data.writeInt(resultFlags)
            val transacted = channel.transact(OfficeHostSaveHandoffPolicy.TRANSACTION_DELIVER_PICK_RESULT, data, reply, 0)
            transacted && reply.readInt() == 1
        } catch (e: Exception) {
            false
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Pushes one typed receipt to the App host (mirror of the in-process listener). */
    @JvmStatic
    fun postReceipt(channel: IBinder?, receipt: OfficeSaveReceipt): Boolean {
        if (channel == null || !channel.pingBinder()) return false
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeHostSaveHandoffPolicy.DESCRIPTOR)
            writeReceipt(data, receipt)
            val transacted = channel.transact(OfficeHostSaveHandoffPolicy.TRANSACTION_SAVE_RECEIPT, data, reply, 0)
            transacted && reply.readInt() == 1
        } catch (e: Exception) {
            false
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /**
     * Pushes one verified internal-save notice to the App host. True only
     * when the App verified and snapshotted the exact bytes for this op.
     * Any transport/shape/refusal problem is false; the caller keeps the
     * editor open and retains the working copy.
     */
    @JvmStatic
    fun postInternalSave(
        channel: IBinder?,
        notice: OfficeHostSaveHandoffPolicy.InternalSaveNotice,
    ): Int {
        if (channel == null || !channel.pingBinder()) {
            return OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED
        }
        if (OfficeHostSaveHandoffPolicy.validateInternalSave(
                notice.opId,
                notice.sessionToken,
                notice.generation,
                notice.format,
                notice.workingCopySha256,
                notice.workingCopyBytes,
            ) == null
        ) return OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REJECTED
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeHostSaveHandoffPolicy.DESCRIPTOR)
            writeInternalSave(data, notice)
            val transacted = channel.transact(
                OfficeHostSaveHandoffPolicy.TRANSACTION_INTERNAL_SAVE,
                data,
                reply,
                0,
            )
            if (transacted) reply.readInt() else OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED
        } catch (e: Exception) {
            OfficeHostSaveHandoffPolicy.INTERNAL_SAVE_REFUSED
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Pushes one live edit-state snapshot to the App host. */
    @JvmStatic
    fun postEditState(channel: IBinder?, state: OfficeEditState): Boolean {
        if (channel == null || !channel.pingBinder()) return false
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeHostSaveHandoffPolicy.DESCRIPTOR)
            writeEditState(data, state)
            val transacted = channel.transact(OfficeHostSaveHandoffPolicy.TRANSACTION_EDIT_STATE, data, reply, 0)
            transacted && reply.readInt() == 1
        } catch (e: Exception) {
            false
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    // ------------------------------------------------------------------
    // Flat, versioned marshalling (fixed field order; never a Java-serialized object graph)
    // ------------------------------------------------------------------

    private fun writeReceipt(parcel: Parcel, receipt: OfficeSaveReceipt) {
        parcel.writeInt(OfficeHostSaveHandoffPolicy.SCHEMA_VERSION)
        parcel.writeString(receipt.opId)
        parcel.writeString(receipt.sessionToken)
        parcel.writeLong(receipt.generation)
        parcel.writeString(receipt.operation.name)
        parcel.writeString(receipt.state.name)
        parcel.writeString(receipt.format)
        parcel.writeString(receipt.suggestedName)
        parcel.writeString(receipt.expectedBaseSha256)
        parcel.writeString(receipt.workingCopySha256)
        parcel.writeLong(receipt.workingCopyBytes)
        parcel.writeString(receipt.outputDocumentPath)
        parcel.writeString(receipt.outputSha256)
        parcel.writeLong(receipt.outputBytes)
        parcel.writeString(receipt.failure?.name)
        parcel.writeString(receipt.message?.take(512))
        parcel.writeInt(if (receipt.cancelRequested) 1 else 0)
        parcel.writeString(receipt.attestation.take(128))
        parcel.writeLong(receipt.submittedAtElapsedMs)
        parcel.writeLong(receipt.completedAtElapsedMs)
    }

    /** Single ordered reader; field order must match [writeReceipt] exactly. */
    private fun readReceipt(parcel: Parcel): OfficeSaveReceipt? {
        return try {
            if (parcel.readInt() != OfficeHostSaveHandoffPolicy.SCHEMA_VERSION) return null
            val opId = parcel.readString() ?: return null
            val sessionToken = parcel.readString() ?: return null
            val generation = parcel.readLong()
            val operation = runCatching { OfficeSaveOperation.valueOf(parcel.readString() ?: "") }.getOrNull() ?: return null
            val state = runCatching { OfficeSaveState.valueOf(parcel.readString() ?: "") }.getOrNull() ?: return null
            val format = parcel.readString()
            val suggestedName = parcel.readString()
            val expectedBaseSha256 = parcel.readString()
            val workingCopySha256 = parcel.readString()
            val workingCopyBytes = parcel.readLong()
            val outputDocumentPath = parcel.readString()
            val outputSha256 = parcel.readString()
            val outputBytes = parcel.readLong()
            val failure = parcel.readString()?.takeIf { it.isNotEmpty() }?.let {
                runCatching { OfficeSaveFailureCode.valueOf(it) }.getOrNull()
            }
            val message = parcel.readString()
            val cancelRequested = parcel.readInt() == 1
            val attestation = parcel.readString() ?: ""
            val submittedAtElapsedMs = parcel.readLong()
            val completedAtElapsedMs = parcel.readLong()
            OfficeSaveReceipt(
                opId = opId,
                sessionToken = sessionToken,
                generation = generation,
                operation = operation,
                state = state,
                format = format,
                suggestedName = suggestedName,
                expectedBaseSha256 = expectedBaseSha256,
                workingCopySha256 = workingCopySha256,
                workingCopyBytes = workingCopyBytes,
                outputDocumentPath = outputDocumentPath,
                outputSha256 = outputSha256,
                outputBytes = outputBytes,
                failure = failure,
                message = message,
                cancelRequested = cancelRequested,
                attestation = attestation,
                submittedAtElapsedMs = submittedAtElapsedMs,
                completedAtElapsedMs = completedAtElapsedMs,
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun writeInternalSave(
        parcel: Parcel,
        notice: OfficeHostSaveHandoffPolicy.InternalSaveNotice,
    ) {
        parcel.writeInt(OfficeHostSaveHandoffPolicy.SCHEMA_VERSION)
        parcel.writeString(notice.opId)
        parcel.writeString(notice.sessionToken)
        parcel.writeLong(notice.generation)
        parcel.writeString(notice.format)
        parcel.writeString(notice.workingCopySha256)
        parcel.writeLong(notice.workingCopyBytes)
    }

    /** Single ordered reader; field order must match [writeInternalSave] exactly. */
    private fun readInternalSave(parcel: Parcel): OfficeHostSaveHandoffPolicy.InternalSaveNotice? {
        return try {
            if (parcel.readInt() != OfficeHostSaveHandoffPolicy.SCHEMA_VERSION) return null
            OfficeHostSaveHandoffPolicy.validateInternalSave(
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

    private fun writeEditState(parcel: Parcel, state: OfficeEditState) {
        parcel.writeInt(OfficeHostSaveHandoffPolicy.SCHEMA_VERSION)
        parcel.writeString(state.sessionToken)
        parcel.writeLong(state.generation)
        parcel.writeString(state.stateName)
        parcel.writeInt(if (state.editRequested) 1 else 0)
        parcel.writeInt(if (state.pageEditMode) 1 else 0)
        parcel.writeInt(if (state.editPermissionEstablished) 1 else 0)
        parcel.writeInt(if (state.documentModified == null) -1 else if (state.documentModified) 1 else 0)
        parcel.writeString(state.undoState)
        parcel.writeString(state.redoState)
    }

    private fun readEditState(parcel: Parcel): OfficeEditState? {
        return try {
            if (parcel.readInt() != OfficeHostSaveHandoffPolicy.SCHEMA_VERSION) return null
            val token = parcel.readString() ?: return null
            val generation = parcel.readLong()
            val stateName = parcel.readString() ?: return null
            val editRequested = parcel.readInt() == 1
            val pageEditMode = parcel.readInt() == 1
            val editPermissionEstablished = parcel.readInt() == 1
            val modifiedWord = parcel.readInt()
            val documentModified = if (modifiedWord < 0) null else modifiedWord == 1
            val undoState = parcel.readString()
            val redoState = parcel.readString()
            OfficeEditState(
                sessionToken = token,
                generation = generation,
                stateName = stateName,
                editRequested = editRequested,
                pageEditMode = pageEditMode,
                editPermissionEstablished = editPermissionEstablished,
                documentModified = documentModified,
                undoState = undoState,
                redoState = redoState,
            )
        } catch (e: Exception) {
            null
        }
    }
}
