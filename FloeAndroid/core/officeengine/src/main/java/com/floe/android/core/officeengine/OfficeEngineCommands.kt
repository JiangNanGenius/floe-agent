// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import com.floe.android.core.officeengine.precision.OfficePrecisionAction
import com.floe.android.core.officeengine.precision.OfficePrecisionAnswer
import com.floe.android.core.officeengine.precision.OfficePrecisionContentKind
import com.floe.android.core.officeengine.precision.OfficePrecisionContentReadback
import com.floe.android.core.officeengine.precision.OfficePrecisionFailure
import com.floe.android.core.officeengine.precision.OfficePrecisionProtocol
import com.floe.android.core.officeengine.precision.OfficePrecisionPreEffectEvidence
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionState
import com.floe.android.core.officeengine.precision.OfficePrecisionTarget

/**
 * Pure transaction table for the narrow App→engine command surface.
 *
 * The engine Service is NOT exported; only this same application's processes
 * can bind it (same UID). The default (App) process binds it with an explicit
 * Intent carrying its [OfficeHostSaveChannel.parentBinder] so receipts and
 * edit-state events flow back; the engine answers only these transactions,
 * re-checks the interface descriptor and the calling UID on every call, and
 * fences every command by the exact session token + mount generation (a
 * stale or foreign identity is refused, never applied to a live mount).
 *
 * This surface adds NO new authority: it can only ask the engine to do what
 * the in-process viewer chrome can already do for the same exact mount
 * (flush the owned working copy, export to a module-private staged output,
 * toggle page edit mode, run undo/redo, read observed state/diagnostics).
 */
object OfficeEngineCommandsPolicy {

    const val DESCRIPTOR = "com.floe.android.core.officeengine.EngineCommands"

    /**
     * Distinct explicit ACTION identifying the cross-process command bind.
     *
     * Why an action and not an extra (Main integration review 2026-10-26):
     * Android caches the FIRST IBinder returned by onBind for a matching
     * bind-Intent identity, and Intent.filterEquals compares
     * action/data/type/class/categories — NOT extras. The viewer Activity's
     * in-process LocalBinder bind targets the same explicit component, so an
     * extras-only switch could hand either binder to the wrong client
     * depending on bind order. A distinct action makes the two binds two
     * genuinely distinct identities with separately cached binders.
     */
    const val ACTION_ENGINE_COMMANDS = "com.floe.android.office.action.ENGINE_COMMANDS"

    /** Bind-intent extra carrying the App-side [OfficeHostSaveChannel] parent binder. */
    const val EXTRA_HOST_SAVE_CHANNEL = "com.floe.android.office.HOST_SAVE_CHANNEL"

    const val TRANSACTION_SUBMIT_SAVE = 20
    const val TRANSACTION_CANCEL_SAVE = 21
    const val TRANSACTION_REQUEST_EDIT = 22
    const val TRANSACTION_REQUEST_EDIT_HISTORY = 23
    const val TRANSACTION_READ_STATE = 24
    const val TRANSACTION_READ_DIAGNOSTICS = 25

    /**
     * App→module settlement of one Save-Copy handoff after the App's real
     * provider write + readback (COPY_SAVED/COPY_FAILED/COPY_CANCELLED),
     * fenced by exact op + session token + native mount generation.
     */
    const val TRANSACTION_SETTLE_HOST_SAVE = 26

    /**
     * App→module: the native mount generation for an exact session token
     * (0 when no live mount). The session token is App-minted (not secret);
     * the engine-internal generation is what every fenced command needs, so
     * the App adapter acquires it here deterministically instead of waiting
     * for the first event. Per-save App ordinals stay distinct from this
     * native generation.
     */
    const val TRANSACTION_READ_GENERATION = 27

    /**
     * App→module: (re)register the host save-channel binder explicitly.
     * onBind fires only once per cached bind identity, so a later bind with
     * a fresh channel (App-side recreation without an engine process
     * restart) must update the registration through this transaction rather
     * than relying on extras being re-read.
     */
    const val TRANSACTION_REGISTER_HOST_CHANNEL = 28

    /**
     * App→module: admit one TYPED precision operation (G05-R2 P-A).
     *
     * Transaction-table verification (2026-10-27): this descriptor's actual
     * table is exactly the constants in this object (20–28 before this
     * addition; the binder's onTransact allow-set mirrors it and every
     * other code falls through to super). The module's other binders
     * (CloseAck=1, HostSave=2..5) use DIFFERENT descriptors/objects, and
     * the platform's own codes (INTERFACE_TRANSACTION/PING/DUMP/…) live far
     * above the app range — so 29/30 are genuinely free, not assumed.
     *
     * The request carries ONLY the structured allowlisted action + typed
     * parameters (never raw wire/UNO/key/body strings); the reply is the
     * coarse admission code, and the exact typed result (including the
     * precise refusal failure) is read through
     * [TRANSACTION_READ_PRECISION_ANSWER].
     */
    const val TRANSACTION_POST_PRECISION_COMMAND = 29

    /**
     * App→module: read (and consume) the terminal result of one exact
     * fenced precision operation — the ONLY path typed answer content
     * leaves the engine, to the same-UID owner behind the exact
     * token/generation fence.
     */
    const val TRANSACTION_READ_PRECISION_ANSWER = 30

    /** SUBMIT_SAVE reply codes. */
    const val SUBMIT_ACCEPTED = 1
    const val SUBMIT_REJECTED_SHAPE = -1
    const val SUBMIT_REJECTED_SESSION = -2
    const val SUBMIT_REJECTED_BUSY = -3
    const val SUBMIT_REJECTED_STATE = -4

    /** POST_PRECISION_COMMAND reply codes (typed failure via READ_PRECISION_ANSWER). */
    const val PRECISION_ACCEPTED = 1
    const val PRECISION_REJECTED_SHAPE = -1
    const val PRECISION_REJECTED_SESSION = -2
    const val PRECISION_REJECTED_BUSY = -3
    const val PRECISION_REJECTED_STATE = -4
    const val PRECISION_REJECTED_SIZE = -5

    /** CANCEL_SAVE reply codes. */
    const val CANCEL_UNKNOWN_OP = 0
    const val CANCEL_CANCELLED_BEFORE_DISPATCH = 1
    const val CANCEL_STILL_IN_FLIGHT = 2
}

/**
 * App-process client for the engine command surface. Obtain the binder via
 * [bindIntent] + Context.bindService (the Service's onBind returns this
 * command binder when the bind Intent carries [EXTRA_HOST_SAVE_CHANNEL]),
 * then wrap it: `OfficeEngineCommands(binder)`.
 *
 * All calls are synchronous binder transactions, fail-closed (false/null on
 * any transport or fence problem), and safe from any thread. Events flow
 * back through the [OfficeHostSaveChannel.parentBinder] supplied at bind
 * time (TRANSACTION_SAVE_RECEIPT / TRANSACTION_EDIT_STATE).
 */
class OfficeEngineCommands(private val binder: IBinder) {

    /**
     * Explicit bind Intent for the engine Service from the App process.
     * Carries [ACTION_ENGINE_COMMANDS] so the platform treats this bind as a
     * DISTINCT identity from the viewer Activity's plain LocalBinder bind
     * (filterEquals excludes extras; see the policy note). [hostChannel] is
     * the App's [OfficeHostSaveChannel.parentBinder]; it may be null when
     * the App only needs fire-and-forget commands (receipts are then
     * observable only through Activity results / readState), and can be
     * (re)registered later via [registerHostChannel].
     */
    companion object {
        @JvmStatic
        fun bindIntent(context: Context, hostChannel: IBinder?): Intent =
            Intent(context, OfficeEngineService::class.java).apply {
                action = OfficeEngineCommandsPolicy.ACTION_ENGINE_COMMANDS
                // An IBinder is NOT a Parcelable: it travels through the
                // Bundle's putBinder/getBinder pair (the R1 close-ack
                // pattern), never putExtra.
                val extrasBundle = android.os.Bundle()
                extrasBundle.putBinder(OfficeEngineCommandsPolicy.EXTRA_HOST_SAVE_CHANNEL, hostChannel)
                putExtras(extrasBundle)
            }
    }

    private fun <T> transact(code: Int, body: (Parcel) -> Unit, read: (Parcel) -> T): T? {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeEngineCommandsPolicy.DESCRIPTOR)
            body(data)
            if (!binder.transact(code, data, reply, 0)) return null
            read(reply)
        } catch (e: Exception) {
            null
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /** Submits one validated save/export op. Reply codes: [OfficeEngineCommandsPolicy]. */
    fun submitSave(request: OfficeSaveRequest): Int? =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_SUBMIT_SAVE,
            { data ->
                data.writeString(request.opId)
                data.writeString(request.sessionToken)
                data.writeLong(request.generation)
                data.writeString(request.operation.name)
                data.writeString(request.format)
                data.writeString(request.options)
                data.writeString(request.suggestedName)
                data.writeInt(if (request.saveIfUnmodified) 1 else 0)
            },
            { reply -> reply.readInt() },
        )

    /** Cancel is honest: only pre-dispatch cancellation exists (no native save cancel). */
    fun cancelSave(opId: String, sessionToken: String, generation: Long): Int? =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_CANCEL_SAVE,
            { data ->
                data.writeString(opId)
                data.writeString(sessionToken)
                data.writeLong(generation)
            },
            { reply -> reply.readInt() },
        )

    /**
     * Host-driven edit-mode toggle for the exact mount. True only when the
     * command was accepted for processing; the authoritative page/native
     * state arrives via the edit-state events / [readState].
     */
    fun requestEdit(sessionToken: String, generation: Long, enable: Boolean): Boolean =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_REQUEST_EDIT,
            { data ->
                data.writeString(sessionToken)
                data.writeLong(generation)
                data.writeInt(if (enable) 1 else 0)
            },
            { reply -> reply.readInt() == 1 },
        ) ?: false

    /** Runs one real `.uno:Undo`/`.uno:Redo` through the engine gate (editable mounts only). */
    fun requestEditHistory(sessionToken: String, generation: Long, redo: Boolean): Boolean =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_REQUEST_EDIT_HISTORY,
            { data ->
                data.writeString(sessionToken)
                data.writeLong(generation)
                data.writeInt(if (redo) 1 else 0)
            },
            { reply -> reply.readInt() == 1 },
        ) ?: false

    /**
     * Settles one Save-Copy handoff back to the foreground viewer after the
     * App's REAL provider write + readback. True only when the exact
     * op/session/generation fence matched a live mount and the settlement was
     * accepted for delivery; the viewer then shows the honest terminal copy
     * outcome (never before). A picker acceptance alone must never be
     * settled here as COPY_SAVED.
     */
    fun settleHostSaveCopy(
        opId: String,
        sessionToken: String,
        generation: Long,
        verdict: OfficeHostSaveVerdict,
        message: String? = null,
    ): Boolean =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_SETTLE_HOST_SAVE,
            { data ->
                data.writeString(opId)
                data.writeString(sessionToken)
                data.writeLong(generation)
                data.writeString(verdict.name)
                data.writeString(message?.take(240))
            },
            { reply -> reply.readInt() == 1 },
        ) ?: false

    /**
     * Native mount generation for the exact session token (0 when no live
     * mount). Acquire this once per viewer launch, then fence every command
     * with it. Per-save App ordinals are the App's own and stay distinct.
     */
    fun readGeneration(sessionToken: String): Long =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_READ_GENERATION,
            { data -> data.writeString(sessionToken) },
            { reply -> reply.readLong() },
        ) ?: 0L

    /**
     * (Re)registers the App host save-channel binder on an already-cached
     * command binding (onBind is NOT re-invoked for a repeat bind with the
     * same identity, so extras alone cannot refresh the channel). Pass null
     * to clear. True when the engine accepted the registration.
     */
    fun registerHostChannel(hostChannel: IBinder?): Boolean =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_REGISTER_HOST_CHANNEL,
            { data -> data.writeStrongBinder(hostChannel) },
            { reply -> reply.readInt() == 1 },
        ) ?: false

    /**
     * Admits one TYPED precision operation (G05-R2 P-A). Returns the coarse
     * admission code ([OfficeEngineCommandsPolicy.PRECISION_ACCEPTED] /
     * PRECISION_REJECTED_*); the EXACT typed result (including the precise
     * refusal failure and any typed answer content) is read through
     * [readPrecisionAnswer]. Null on transport failure (fail-closed; an
     * unknown transport outcome is never dressed up as accepted).
     *
     * The request carries ONLY structured allowlisted actions and typed
     * parameters — raw wire commands, UNO names, key/mouse events and
     * message bodies are not part of this surface.
     */
    fun postPrecisionCommand(request: OfficePrecisionRequest): Int? =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_POST_PRECISION_COMMAND,
            { data -> writePrecisionRequest(data, request) },
            { reply -> reply.readInt() },
        )

    /**
     * Reads (and consumes) the terminal result of one exact fenced
     * precision operation. Null while the operation is pending/in-flight,
     * when the op is unknown to this engine, or when the token/generation
     * fence did not match — never a fabricated result. This is the ONLY
     * path typed answer content leaves the engine.
     */
    fun readPrecisionAnswer(
        opId: String,
        sessionToken: String,
        generation: Long,
    ): OfficePrecisionResult? =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_READ_PRECISION_ANSWER,
            { data ->
                data.writeString(opId)
                data.writeString(sessionToken)
                data.writeLong(generation)
            },
            { reply ->
                if (reply.readInt() != 1) return@transact null
                readPrecisionResult(reply)
            },
        )

    /** Observed edit/dirty/undo state for the exact mount (null when fenced/absent). */
    fun readState(sessionToken: String, generation: Long): OfficeEditState? =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_READ_STATE,
            { data ->
                data.writeString(sessionToken)
                data.writeLong(generation)
            },
            { reply ->
                if (reply.readInt() != 1) return@transact null
                val token = reply.readString() ?: return@transact null
                val gen = reply.readLong()
                val stateName = reply.readString() ?: return@transact null
                val editRequested = reply.readInt() == 1
                val pageEditMode = reply.readInt() == 1
                val editPermissionEstablished = reply.readInt() == 1
                val modifiedWord = reply.readInt()
                OfficeEditState(
                    sessionToken = token,
                    generation = gen,
                    stateName = stateName,
                    editRequested = editRequested,
                    pageEditMode = pageEditMode,
                    editPermissionEstablished = editPermissionEstablished,
                    documentModified = if (modifiedWord < 0) null else modifiedWord == 1,
                    undoState = reply.readString(),
                    redoState = reply.readString(),
                )
            },
        )

    /** Bounded RAM-only diagnostic snapshot (kind to detail), newest last. */
    fun readDiagnostics(sessionToken: String, generation: Long): List<Pair<String, String>>? =
        transact(
            OfficeEngineCommandsPolicy.TRANSACTION_READ_DIAGNOSTICS,
            { data ->
                data.writeString(sessionToken)
                data.writeLong(generation)
            },
            { reply ->
                if (reply.readInt() != 1) return@transact null
                val count = reply.readInt().coerceIn(0, OfficeSessionDiagnostics.MAX_EVENTS)
                (0 until count).mapNotNull {
                    val kind = reply.readString() ?: return@mapNotNull null
                    kind to (reply.readString() ?: "")
                }
            },
        )
}

/**
 * Engine-side command binder (internal). Returned by
 * [OfficeEngineService.onBind] for cross-process binds that carry
 * [OfficeEngineCommandsPolicy.EXTRA_HOST_SAVE_CHANNEL]. Same-UID and
 * descriptor enforcement mirror [OfficeCloseAck]; all fencing by exact
 * token/generation happens in the service methods this dispatches to.
 */
internal class OfficeEngineCommandBinder(
    private val service: OfficeEngineService,
) : Binder() {

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code !in setOf(
                OfficeEngineCommandsPolicy.TRANSACTION_SUBMIT_SAVE,
                OfficeEngineCommandsPolicy.TRANSACTION_CANCEL_SAVE,
                OfficeEngineCommandsPolicy.TRANSACTION_REQUEST_EDIT,
                OfficeEngineCommandsPolicy.TRANSACTION_REQUEST_EDIT_HISTORY,
                OfficeEngineCommandsPolicy.TRANSACTION_READ_STATE,
                OfficeEngineCommandsPolicy.TRANSACTION_READ_DIAGNOSTICS,
                OfficeEngineCommandsPolicy.TRANSACTION_SETTLE_HOST_SAVE,
                OfficeEngineCommandsPolicy.TRANSACTION_READ_GENERATION,
                OfficeEngineCommandsPolicy.TRANSACTION_REGISTER_HOST_CHANNEL,
                OfficeEngineCommandsPolicy.TRANSACTION_POST_PRECISION_COMMAND,
                OfficeEngineCommandsPolicy.TRANSACTION_READ_PRECISION_ANSWER,
            )
        ) {
            return super.onTransact(code, data, reply, flags)
        }
        data.enforceInterface(OfficeEngineCommandsPolicy.DESCRIPTOR)
        if (Binder.getCallingUid() != Process.myUid()) {
            reply?.writeInt(0)
            return true
        }
        when (code) {
            OfficeEngineCommandsPolicy.TRANSACTION_SUBMIT_SAVE -> {
                val opId = data.readString().orEmpty()
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val operation = data.readString()
                val format = data.readString()
                val options = data.readString()
                val suggestedName = data.readString()
                val saveIfUnmodified = data.readInt() == 1
                val result = service.submitSaveFromBinder(
                    opId, token, generation, operation, format, options, suggestedName, saveIfUnmodified,
                )
                reply?.writeInt(result)
            }

            OfficeEngineCommandsPolicy.TRANSACTION_CANCEL_SAVE -> {
                val opId = data.readString().orEmpty()
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                reply?.writeInt(service.cancelSaveFromBinder(opId, token, generation))
            }

            OfficeEngineCommandsPolicy.TRANSACTION_REQUEST_EDIT -> {
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val enable = data.readInt() == 1
                reply?.writeInt(if (service.requestEditFromBinder(token, generation, enable)) 1 else 0)
            }

            OfficeEngineCommandsPolicy.TRANSACTION_REQUEST_EDIT_HISTORY -> {
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val redo = data.readInt() == 1
                reply?.writeInt(if (service.requestEditHistoryFromBinder(token, generation, redo)) 1 else 0)
            }

            OfficeEngineCommandsPolicy.TRANSACTION_READ_STATE -> {
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val state = service.editStateFromBinder(token, generation)
                if (state == null) {
                    reply?.writeInt(0)
                } else {
                    reply?.writeInt(1)
                    reply?.writeString(state.sessionToken)
                    reply?.writeLong(state.generation)
                    reply?.writeString(state.stateName)
                    reply?.writeInt(if (state.editRequested) 1 else 0)
                    reply?.writeInt(if (state.pageEditMode) 1 else 0)
                    reply?.writeInt(if (state.editPermissionEstablished) 1 else 0)
                    reply?.writeInt(
                        when (state.documentModified) {
                            null -> -1
                            true -> 1
                            false -> 0
                        },
                    )
                    reply?.writeString(state.undoState)
                    reply?.writeString(state.redoState)
                }
            }

            OfficeEngineCommandsPolicy.TRANSACTION_READ_DIAGNOSTICS -> {
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val events = service.diagnosticsFromBinder(token, generation)
                reply?.writeInt(if (events == null) 0 else 1)
                if (events != null) {
                    val bounded = events.take(OfficeSessionDiagnostics.MAX_EVENTS)
                    reply?.writeInt(bounded.size)
                    bounded.forEach { event ->
                        reply?.writeString(event.kind)
                        reply?.writeString(event.detail)
                    }
                }
            }

            OfficeEngineCommandsPolicy.TRANSACTION_SETTLE_HOST_SAVE -> {
                val opId = data.readString().orEmpty()
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val verdictName = data.readString()
                val message = data.readString()
                reply?.writeInt(
                    if (service.settleHostSaveFromBinder(opId, token, generation, verdictName, message)) 1 else 0,
                )
            }

            OfficeEngineCommandsPolicy.TRANSACTION_READ_GENERATION -> {
                val token = data.readString().orEmpty()
                reply?.writeLong(service.currentGenerationFor(token))
            }

            OfficeEngineCommandsPolicy.TRANSACTION_REGISTER_HOST_CHANNEL -> {
                val channel = data.readStrongBinder()
                reply?.writeInt(if (service.registerHostChannelFromBinder(channel)) 1 else 0)
            }

            OfficeEngineCommandsPolicy.TRANSACTION_POST_PRECISION_COMMAND -> {
                // Oversize requests are REFUSED whole (fail-closed); the
                // bounded surface never silently truncates a caller payload.
                if (data.dataSize() > OfficePrecisionProtocol.MAX_REQUEST_BYTES) {
                    reply?.writeInt(OfficeEngineCommandsPolicy.PRECISION_REJECTED_SIZE)
                } else {
                    val request = readPrecisionRequest(data)
                    if (request == null) {
                        reply?.writeInt(OfficeEngineCommandsPolicy.PRECISION_REJECTED_SHAPE)
                    } else {
                        val result = service.postPrecisionCommandFromBinder(request)
                        reply?.writeInt(precisionAdmissionCode(result))
                    }
                }
            }

            OfficeEngineCommandsPolicy.TRANSACTION_READ_PRECISION_ANSWER -> {
                val opId = data.readString().orEmpty()
                val token = data.readString().orEmpty()
                val generation = data.readLong()
                val result = service.readPrecisionAnswerFromBinder(opId, token, generation)
                if (result == null) {
                    reply?.writeInt(0)
                } else {
                    writePrecisionResult(reply, result)
                }
            }
        }
        return true
    }
}

// ----------------------------------------------------------------------
// Precision parcel marshalling (G05-R2 P-A). Field order MUST stay in sync
// between the write/read pairs. Bounded by contract: request text ≤
// MAX_TEXT_BYTES, answer payloads ≤ MAX_ANSWER_BYTES (both enforced before
// marshalling); nullable scalars travel as -1 markers (the readState
// pattern), nullable strings as null.
// ----------------------------------------------------------------------

/** Coarse admission code for one precision result (exact failure via READ). */
internal fun precisionAdmissionCode(result: OfficePrecisionResult): Int {
    if (result.state == OfficePrecisionState.ADMITTED) {
        return OfficeEngineCommandsPolicy.PRECISION_ACCEPTED
    }
    return when (result.failure) {
        OfficePrecisionFailure.INVALID_REQUEST,
        OfficePrecisionFailure.CONTENT_UNSAFE,
        -> OfficeEngineCommandsPolicy.PRECISION_REJECTED_SHAPE
        OfficePrecisionFailure.SESSION_MISMATCH,
        OfficePrecisionFailure.SESSION_ENDING,
        OfficePrecisionFailure.OWNER_MISMATCH,
        -> OfficeEngineCommandsPolicy.PRECISION_REJECTED_SESSION
        OfficePrecisionFailure.MUTATION_IN_FLIGHT,
        OfficePrecisionFailure.SAVE_IN_FLIGHT,
        OfficePrecisionFailure.QUEUE_FULL,
        -> OfficeEngineCommandsPolicy.PRECISION_REJECTED_BUSY
        OfficePrecisionFailure.REQUEST_TOO_LARGE,
        OfficePrecisionFailure.ANSWER_TOO_LARGE,
        -> OfficeEngineCommandsPolicy.PRECISION_REJECTED_SIZE
        else -> OfficeEngineCommandsPolicy.PRECISION_REJECTED_STATE
    }
}

private fun writePrecisionRequest(data: Parcel, request: OfficePrecisionRequest) {
    data.writeString(request.opId)
    data.writeString(request.sessionToken)
    data.writeLong(request.generation)
    data.writeString(request.action.name)
    data.writeString(request.text)
    data.writeString(request.contentKind?.name)
    data.writeString(request.cellAddress)
    data.writeString(request.partId)
    data.writeString(request.targetHandle)
    data.writeString(request.ownerTaskId)
    data.writeString(request.workspaceId)
}

private fun readPrecisionRequest(data: Parcel): OfficePrecisionRequest? {
    val opId = data.readString() ?: return null
    val sessionToken = data.readString() ?: return null
    val generation = data.readLong()
    val actionName = data.readString() ?: return null
    val action = runCatching { OfficePrecisionAction.valueOf(actionName) }.getOrNull()
        ?: return null
    val text = data.readString()
    val contentKindName = data.readString()
    val contentKind = contentKindName?.let { name ->
        runCatching { OfficePrecisionContentKind.valueOf(name) }.getOrNull()
    }
    val cellAddress = data.readString()
    val partId = data.readString()
    val targetHandle = data.readString()
    val ownerTaskId = data.readString()
    val workspaceId = data.readString()
    return OfficePrecisionRequest(
        opId = opId,
        sessionToken = sessionToken,
        generation = generation,
        action = action,
        text = text,
        contentKind = contentKind,
        cellAddress = cellAddress,
        partId = partId,
        targetHandle = targetHandle,
        ownerTaskId = ownerTaskId,
        workspaceId = workspaceId,
    )
}

private fun writePrecisionResult(reply: Parcel?, result: OfficePrecisionResult) {
    reply ?: return
    reply.writeInt(1)
    reply.writeString(result.opId)
    reply.writeString(result.sessionToken)
    reply.writeLong(result.generation)
    reply.writeString(result.state.name)
    reply.writeString(result.action.name)
    reply.writeString(result.failure?.name)
    reply.writeString(result.detail)
    reply.writeString(result.attestation)
    reply.writeLong(result.submittedAtElapsedMs)
    reply.writeLong(result.completedAtElapsedMs)
    when (val answer = result.answer) {
        null -> reply.writeInt(0)
        is OfficePrecisionAnswer.TargetCaptured -> {
            val t = answer.target
            reply.writeInt(1)
            reply.writeString(t.handleId)
            reply.writeLong(t.generation)
            reply.writeString(t.sourceId)
            reply.writeString(t.sourceRevision)
            reply.writeString(t.sourceLogicalPath)
            reply.writeString(t.workspaceId)
            reply.writeString(t.ownerTaskId)
            reply.writeString(t.workingCopySha256)
            reply.writeLong(t.workingCopyBytes)
            reply.writeLong(t.inputEpoch)
            reply.writeLong(t.editEpoch)
            reply.writeInt(boolWord(t.documentModified))
            reply.writeString(t.docType)
            reply.writeInt(t.partsCount ?: -1)
            reply.writeString(t.selectedPart)
            reply.writeLong(t.capturedAtElapsedMs)
            reply.writeLong(t.expiresAtElapsedMs)
        }
        is OfficePrecisionAnswer.DocumentContext -> {
            reply.writeInt(2)
            reply.writeString(answer.docType)
            reply.writeInt(answer.partsCount ?: -1)
            reply.writeString(answer.selectedPart)
            reply.writeInt(answer.widthTwip ?: -1)
            reply.writeInt(answer.heightTwip ?: -1)
            reply.writeInt(answer.viewId ?: -1)
            reply.writeInt(boolWord(answer.readOnly))
            reply.writeInt(boolWord(answer.documentModified))
        }
        is OfficePrecisionAnswer.TextSelection -> {
            reply.writeInt(3)
            reply.writeString(answer.text)
            reply.writeInt(answer.byteCount)
            reply.writeInt(if (answer.multiFormatJson) 1 else 0)
        }
        is OfficePrecisionAnswer.CellCursor -> {
            reply.writeInt(4)
            reply.writeInt(answer.column ?: -1)
            reply.writeInt(answer.row ?: -1)
            reply.writeInt(answer.xTwip ?: -1)
            reply.writeInt(answer.yTwip ?: -1)
            reply.writeInt(answer.widthTwip ?: -1)
            reply.writeInt(answer.heightTwip ?: -1)
            reply.writeInt(if (answer.empty) 1 else 0)
        }
        is OfficePrecisionAnswer.PresentationInfo -> {
            reply.writeInt(5)
            reply.writeInt(answer.byteCount)
            reply.writeInt(answer.slideCount ?: -1)
        }
        is OfficePrecisionAnswer.SlideSelected -> {
            reply.writeInt(6)
            reply.writeString(answer.shownPart)
        }
        is OfficePrecisionAnswer.TextSelected -> {
            reply.writeInt(7)
            reply.writeInt(answer.effectPayloadBytes)
        }
        is OfficePrecisionAnswer.MutationApplied -> {
            reply.writeInt(8)
            val steps = answer.steps.take(32)
            reply.writeInt(steps.size)
            steps.forEach { reply.writeString(it) }
            reply.writeInt(answer.pastedBytes)
            reply.writeString(answer.contentReadback.name)
            reply.writeString(answer.workingCopySha256)
            reply.writeString(answer.consumedTargetHandle)
            val evidence = answer.preEffectEvidence
            reply.writeInt(if (evidence == null) 0 else 1)
            if (evidence != null) {
                reply.writeString(evidence.opId)
                reply.writeString(evidence.sessionToken)
                reply.writeLong(evidence.generation)
                reply.writeString(evidence.targetHandle)
                reply.writeString(evidence.partId)
                reply.writeLong(evidence.inputEpoch)
                reply.writeLong(evidence.editEpoch)
                reply.writeString(evidence.selectionText)
                reply.writeInt(evidence.selectionByteCount)
            }
        }
    }
}

private fun readPrecisionResult(reply: Parcel): OfficePrecisionResult? {
    val opId = reply.readString() ?: return null
    val sessionToken = reply.readString().orEmpty()
    val generation = reply.readLong()
    val stateName = reply.readString() ?: return null
    val actionName = reply.readString() ?: return null
    val state = runCatching { OfficePrecisionState.valueOf(stateName) }.getOrNull()
        ?: return null
    val action = runCatching { OfficePrecisionAction.valueOf(actionName) }.getOrNull()
        ?: return null
    val failureName = reply.readString()
    val failure = failureName?.let { name ->
        runCatching { OfficePrecisionFailure.valueOf(name) }.getOrNull()
    }
    val detail = reply.readString()
    val attestation = reply.readString().orEmpty()
    val submittedAt = reply.readLong()
    val completedAt = reply.readLong()
    val answer = when (reply.readInt()) {
        0 -> null
        1 -> OfficePrecisionAnswer.TargetCaptured(
            OfficePrecisionTarget(
                handleId = reply.readString().orEmpty(),
                generation = reply.readLong(),
                sourceId = reply.readString(),
                sourceRevision = reply.readString(),
                sourceLogicalPath = reply.readString(),
                workspaceId = reply.readString(),
                ownerTaskId = reply.readString(),
                workingCopySha256 = reply.readString(),
                workingCopyBytes = reply.readLong(),
                inputEpoch = reply.readLong(),
                editEpoch = reply.readLong(),
                documentModified = wordBool(reply.readInt()),
                docType = reply.readString(),
                partsCount = reply.readInt().takeIf { it >= 0 },
                selectedPart = reply.readString(),
                capturedAtElapsedMs = reply.readLong(),
                expiresAtElapsedMs = reply.readLong(),
            ),
        )
        2 -> OfficePrecisionAnswer.DocumentContext(
            docType = reply.readString(),
            partsCount = reply.readInt().takeIf { it >= 0 },
            selectedPart = reply.readString(),
            widthTwip = reply.readInt().takeIf { it >= 0 },
            heightTwip = reply.readInt().takeIf { it >= 0 },
            viewId = reply.readInt().takeIf { it >= 0 },
            readOnly = wordBool(reply.readInt()),
            documentModified = wordBool(reply.readInt()),
        )
        3 -> OfficePrecisionAnswer.TextSelection(
            text = reply.readString().orEmpty(),
            byteCount = reply.readInt(),
            multiFormatJson = reply.readInt() == 1,
        )
        4 -> OfficePrecisionAnswer.CellCursor(
            column = reply.readInt().takeIf { it >= 0 },
            row = reply.readInt().takeIf { it >= 0 },
            xTwip = reply.readInt().takeIf { it >= 0 },
            yTwip = reply.readInt().takeIf { it >= 0 },
            widthTwip = reply.readInt().takeIf { it >= 0 },
            heightTwip = reply.readInt().takeIf { it >= 0 },
            empty = reply.readInt() == 1,
        )
        5 -> OfficePrecisionAnswer.PresentationInfo(
            byteCount = reply.readInt(),
            slideCount = reply.readInt().takeIf { it >= 0 },
        )
        6 -> OfficePrecisionAnswer.SlideSelected(shownPart = reply.readString().orEmpty())
        7 -> OfficePrecisionAnswer.TextSelected(effectPayloadBytes = reply.readInt())
        8 -> {
            val count = reply.readInt().coerceIn(0, 32)
            val steps = (0 until count).mapNotNull { reply.readString() }
            val pastedBytes = reply.readInt()
            val readbackName = reply.readString()
            val readback = readbackName?.let { name ->
                runCatching { OfficePrecisionContentReadback.valueOf(name) }.getOrNull()
            } ?: OfficePrecisionContentReadback.NOT_ATTEMPTED
            val workingCopySha256 = reply.readString()
            val consumedTargetHandle = reply.readString()
            val preEffectEvidence = if (reply.readInt() == 1) {
                OfficePrecisionPreEffectEvidence(
                    opId = reply.readString().orEmpty(),
                    sessionToken = reply.readString().orEmpty(),
                    generation = reply.readLong(),
                    targetHandle = reply.readString().orEmpty(),
                    partId = reply.readString().orEmpty(),
                    inputEpoch = reply.readLong(),
                    editEpoch = reply.readLong(),
                    selectionText = reply.readString().orEmpty(),
                    selectionByteCount = reply.readInt(),
                )
            } else {
                null
            }
            OfficePrecisionAnswer.MutationApplied(
                steps = steps,
                pastedBytes = pastedBytes,
                contentReadback = readback,
                workingCopySha256 = workingCopySha256,
                consumedTargetHandle = consumedTargetHandle,
                preEffectEvidence = preEffectEvidence,
            )
        }
        else -> null
    }
    return OfficePrecisionResult(
        opId = opId,
        sessionToken = sessionToken,
        generation = generation,
        action = action,
        state = state,
        failure = failure,
        detail = detail,
        answer = answer,
        attestation = attestation,
        submittedAtElapsedMs = submittedAt,
        completedAtElapsedMs = completedAt,
    )
}

private fun boolWord(value: Boolean?): Int = when (value) {
    null -> -1
    true -> 1
    false -> 0
}

private fun wordBool(word: Int): Boolean? = when {
    word < 0 -> null
    else -> word == 1
}
