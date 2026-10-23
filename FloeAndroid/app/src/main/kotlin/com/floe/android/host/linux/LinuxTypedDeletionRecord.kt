// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.serialization.json.JsonObject

/**
 * The ONE bounded, RAM-only holder of the LAST original typed
 * `conversation.delete` outcome, projected read-only into the EXISTING
 * explicitly-opened Diagnostics & About details sheet.
 *
 * This is a projection of an EXISTING host outcome, not a new mechanism:
 *  * the ONLY writer is the existing `conversation.delete` Completed
 *    callback in ConversationHostController, feeding it the reply bytes the
 *    host already receives — no new reader, no JNI/C-ABI surface, no DB,
 *    no permission, no retry, no control, no filesystem or authority scan;
 *  * the stored value is already the CLOSED bounded projection
 *    ([LocalRuntimeProofProjection.projectTypedDeletion]) — enumerated
 *    tokens, canonical UUID echo, 32-hex ticket, full-64-hex digest or the
 *    fixed redacted/unavailable markers. It never carries paths, row
 *    content, commands, arguments or secrets;
 *  * exactly one record lives in RAM; the Root-generation gate at READ
 *    time (LinuxRuntimeCleanupPump) means an unbound or different
 *    generation's record can never present itself as a CURRENT cleared
 *    target claim;
 *  * it claims nothing: the typed-deletion outcome and the cleanup lane's
 *    own settled receipts remain separate truths.
 */
internal object LinuxTypedDeletionRecord {

    /** One captured outcome: the ACTUAL dispatch/native Root epoch when the
     *  ORIGINAL operation context already exposed one (null means the host
     *  epoch was honestly unavailable at capture time, never a guess). */
    class Entry(val epoch: Long?, val projected: JsonObject)

    private val lock = Any()

    @Volatile
    private var last: Entry? = null

    fun observe(entry: Entry) = synchronized(lock) { last = entry }

    fun snapshot(): Entry? = last

    fun clear() = synchronized(lock) { last = null }
}
