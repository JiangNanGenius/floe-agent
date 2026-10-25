// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process

/**
 * Android-side wrapper for [OfficeCloseAckPolicy]: one narrow synchronous
 * Binder endpoint used to acknowledge an EXACT current user close-intent
 * from the `:floe_office` viewer process to the App process BEFORE the
 * native BYE that ends that process (bypassing all Java results — see
 * [OfficeCloseAckPolicy]).
 *
 * Capability model (Main decision 2026-10-26): the parent endpoint is sent
 * ONLY inside the non-exported viewer Activity's own launch Intent, so the
 * only process that can hold it is this same application's engine process.
 * No manifest entry, no new permission, no started service, no broadcast
 * (which could race the platform RESULT_CANCELED delivery).
 *
 * The parent side validates, in order: interface descriptor
 * (`enforceInterface`, fail-closed), same-application calling UID, the pure
 * [OfficeCloseAckPolicy.validateShape] payload rules, and — through the
 * supplied callback — exact current-operation ownership (opaque viewer
 * incarnation + session token + VIEWING phase). The engine side treats ANY
 * exception, dead parent or non-accepting answer as "not acknowledged": the
 * close still proceeds natively, and the parent then honestly reports the
 * missing result as a failure.
 */
object OfficeCloseAck {

    /**
     * Parent-side endpoint. [onAck] receives an already shape-validated
     * [OfficeCloseAckPolicy.AckRequest] on a Binder thread and must return
     * true only for the current user close it records. The controller is
     * expected to validate ownership under its own lock inside [onAck].
     * Never cast the returned IBinder in the other process: it arrives as a
     * plain proxy and is used only for this one transaction.
     */
    @JvmStatic
    fun parentBinder(onAck: (OfficeCloseAckPolicy.AckRequest) -> Boolean): IBinder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == OfficeCloseAckPolicy.TRANSACTION_ACK_CLOSE) {
                // Unknown or mismatched interface tokens reject fail-closed
                // (SecurityException travels back to the caller as failure).
                data.enforceInterface(OfficeCloseAckPolicy.DESCRIPTOR)
                val sameUid = Binder.getCallingUid() == Process.myUid()
                android.util.Log.d("OfficeCloseAck", "parent endpoint invoked sameUid=$sameUid")
                val accepted = if (!sameUid) {
                    false
                } else {
                    val request = OfficeCloseAckPolicy.validateShape(
                        token = data.readString(),
                        generation = data.readLong(),
                        incarnation = data.readLong(),
                        reason = data.readString(),
                    )
                    request != null && runCatching { onAck(request) }.getOrDefault(false)
                }
                // writeInt/readInt instead of writeBoolean (API 29): the
                // module minSdk is 28 and this must stay API-safe.
                reply?.writeInt(if (accepted) 1 else 0)
                return true
            }
            return super.onTransact(code, data, reply, flags)
        }
    }

    /**
     * Engine-side synchronous acknowledgement. Returns true only when the
     * parent accepted THIS exact request; any transport problem, parent-side
     * rejection or non-allowlisted reason returns false (never throws).
     * The BYE teardown must proceed regardless of the answer.
     */
    @JvmStatic
    fun ackClose(
        ack: IBinder?,
        sessionToken: String,
        generation: Long,
        viewerIncarnation: Long,
        reason: String?,
    ): Boolean {
        android.util.Log.d("OfficeCloseAck", "attempt capability=${ack != null} reasonAllowed=${reason in OfficeCloseAckPolicy.USER_CLOSE_REASONS} validIncarnation=${viewerIncarnation > 0}")
        if (ack == null || reason !in OfficeCloseAckPolicy.USER_CLOSE_REASONS) return false
        if (!ack.pingBinder()) return false
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(OfficeCloseAckPolicy.DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(generation)
            data.writeLong(viewerIncarnation)
            data.writeString(reason)
            // Synchronous on purpose: the answer must be recorded before the
            // fatal BYE is posted, not raced behind an async broadcast.
            // Fail-closed transport: accepted ONLY when transact() itself
            // returned true AND the reply carries the exact ack word 1
            // (a marshalled exception can arrive as a negative leading int;
            // arbitrary nonzero is never an acknowledgement).
            val transacted = ack.transact(OfficeCloseAckPolicy.TRANSACTION_ACK_CLOSE, data, reply, 0)
            val word = if (transacted) reply.readInt() else 0
            android.util.Log.d("OfficeCloseAck", "transport returned=$transacted exactAck=${word == 1}")
            transacted && word == 1
        } catch (error: Exception) {
            android.util.Log.w("OfficeCloseAck", "transport failed: ${error.javaClass.simpleName}")
            false
        } finally {
            reply.recycle()
            data.recycle()
        }
    }
}
