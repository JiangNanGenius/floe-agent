// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process

/**
 * Android-side wrapper for [OfficeApprovalNoticePolicy]: one narrow
 * synchronous Binder endpoint the foreground viewer Activity polls (only
 * while resumed) to learn whether its OWNING conversation currently holds a
 * captured pending approval — see the policy file for the causal contract
 * and the device evidence behind it.
 *
 * Capability model: the parent endpoint travels ONLY inside the
 * non-exported viewer Activity's own launch Intent, so the only process that
 * can hold it is this same application's engine process (same UID). No
 * manifest entry, no new permission, no started service, no broadcast.
 *
 * The parent side validates, in order: interface descriptor
 * (`enforceInterface`, fail-closed), same-application calling UID, the pure
 * [OfficeApprovalNoticePolicy.validateShape] payload rules, and — through
 * the supplied callback — exact current-operation ownership (opaque viewer
 * incarnation + session token + owner task id) plus the REAL pending-
 * approval lookup of the owning conversation. The engine side treats ANY
 * exception, dead parent or malformed answer as "not pending": the banner
 * simply stays hidden. Asking never mutates anything on either side.
 */
object OfficeApprovalNotice {

    /**
     * Parent-side endpoint. [onQuery] receives an already shape-validated
     * [OfficeApprovalNoticePolicy.Query] on a Binder thread and returns the
     * pending tool name when (and only when) the query names the exact
     * current owned VIEWING operation AND the owning conversation really
     * holds a captured pending approval; null in every other case. The
     * controller performs the ownership check under its own lock and the
     * lookup itself is read-only; neither may throw (runCatching).
     */
    @JvmStatic
    fun parentBinder(onQuery: (OfficeApprovalNoticePolicy.Query) -> String?): IBinder =
        object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code == OfficeApprovalNoticePolicy.TRANSACTION_QUERY_PENDING) {
                    // Unknown or mismatched interface tokens reject fail-closed
                    // (SecurityException travels back to the caller as failure).
                    data.enforceInterface(OfficeApprovalNoticePolicy.DESCRIPTOR)
                    val sameUid = Binder.getCallingUid() == Process.myUid()
                    val toolName = if (!sameUid) {
                        null
                    } else {
                        val query = OfficeApprovalNoticePolicy.validateShape(
                            token = data.readString(),
                            incarnation = data.readLong(),
                            ownerTaskId = data.readString(),
                        )
                        query?.let { runCatching { onQuery(it) }.getOrNull() }
                    }
                    // writeInt/readInt instead of writeBoolean (API 29): the
                    // module minSdk is 28 and this must stay API-safe. Word 1
                    // is accepted ONLY as an exact pending answer carrying the
                    // tool name string; anything else means "not pending".
                    reply?.writeInt(if (toolName != null) 1 else 0)
                    if (toolName != null) reply?.writeString(toolName)
                    return true
                }
                return super.onTransact(code, data, reply, flags)
            }
        }

    /**
     * Viewer-side synchronous query. Returns the pending tool name only when
     * the parent accepted THIS exact query with a pending answer; any
     * transport problem, parent-side rejection, shape failure or malformed
     * reply returns null (never throws). The local shape check runs before
     * the transport so a malformed local state can never reach the parent.
     */
    @JvmStatic
    fun queryPending(
        capability: IBinder?,
        sessionToken: String,
        viewerIncarnation: Long,
        ownerTaskId: String,
    ): String? {
        if (capability == null) return null
        if (OfficeApprovalNoticePolicy.validateShape(sessionToken, viewerIncarnation, ownerTaskId) == null) {
            return null
        }
        if (!capability.pingBinder()) return null
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        val answer: String? = try {
            data.writeInterfaceToken(OfficeApprovalNoticePolicy.DESCRIPTOR)
            data.writeString(sessionToken)
            data.writeLong(viewerIncarnation)
            data.writeString(ownerTaskId)
            // Synchronous on purpose: the answer must reflect the parent's
            // state at the moment of the poll. Fail-closed transport: pending
            // ONLY when transact() itself returned true AND the reply carries
            // the exact answer word 1 followed by a non-empty tool name.
            val transacted = capability.transact(
                OfficeApprovalNoticePolicy.TRANSACTION_QUERY_PENDING,
                data,
                reply,
                0,
            )
            if (!transacted) {
                null
            } else {
                val word = reply.readInt()
                if (word != 1) {
                    null
                } else {
                    reply.readString()?.takeIf { it.isNotEmpty() && it.length <= MAX_TOOL_NAME_CHARS }
                }
            }
        } catch (error: Exception) {
            null
        } finally {
            reply.recycle()
            data.recycle()
        }
        return answer
    }

    /** Tool names crossing this channel are host-projected, non-secret UI
     *  facts (the same string the conversation card already shows); bounded
     *  anyway so a hostile/malformed parent can never mint a wall of text. */
    private const val MAX_TOOL_NAME_CHARS = 128
}
