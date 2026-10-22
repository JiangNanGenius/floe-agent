// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import android.os.IBinder

/**
 * Frozen workspace grant Binder protocol (v1). This is a SEPARATE opaque
 * binder like `RuntimeForegroundPermit`, never RuntimeWire: control traffic
 * is one small bounded standard-JSON object per transaction; bulk bytes ride
 * only as `ParcelFileDescriptor` streams (fd passthrough), never inside
 * JSON, never inside Parcel payload strings.
 *
 * Identity rule (shared with the shell mailbox lane): owner UUID strings
 * (projectID/runID/conversationID/workspaceID) are compared EXACTLY as
 * received from the native mint (Swift canonical uppercase). No side may
 * lowercase or reformat an owner ID inside this protocol.
 */
object WorkspaceBridgeWire {
    const val VERSION = 1
    const val DESCRIPTOR = "com.floe.android.runtime.WorkspaceGrant.v1"

    // Transaction codes. Every request parcel: interface token, then ONE
    // JSON control string (<= MAX_CONTROL_BYTES UTF-8). Requests with a data
    // channel additionally carry a ParcelFileDescriptor AFTER the string;
    // replies with data (BASELINE_DATA) append the PFD after the string.
    const val GET_STATE = IBinder.FIRST_CALL_TRANSACTION + 0        // in {projectID,runID} out {ok,open,rootEpoch,budgets...}
    const val BASELINE_BEGIN = IBinder.FIRST_CALL_TRANSACTION + 1   // in {} out receipt JSON
    const val BASELINE_HEADER = IBinder.FIRST_CALL_TRANSACTION + 2  // in {index} out entry JSON (or end:true)
    const val BASELINE_DATA = IBinder.FIRST_CALL_TRANSACTION + 3    // in {index} out entry JSON + read PFD
    const val BASELINE_FINISH = IBinder.FIRST_CALL_TRANSACTION + 4  // in {appliedCount,appliedBytes} out {state:"ready"}
    const val EXPORT_BEGIN = IBinder.FIRST_CALL_TRANSACTION + 5     // in {} out {state:"staging",budgets}
    const val EXPORT_STAGE = IBinder.FIRST_CALL_TRANSACTION + 6     // in {seq,path,kind,size,mode,linkTarget?} + read PFD out per-entry result
    const val EXPORT_FINISH = IBinder.FIRST_CALL_TRANSACTION + 7    // in {} out outcome JSON (synced/conflict/aborted)
    const val ABORT = IBinder.FIRST_CALL_TRANSACTION + 8            // in {reason} out {state:"aborted"}
    const val STATS = IBinder.FIRST_CALL_TRANSACTION + 9            // in {} out counters only

    /** One control JSON object, UTF-8 bytes (same 64 KiB boundary family). */
    const val MAX_CONTROL_BYTES = 65_536
    /** Identifier strings in control JSON (projectID/runID/sessionKey...). */
    const val MAX_IDENTIFIER_CHARS = 64
    /** Owner identity strings are 36-char canonical UUIDs; session keys 32 hex. */
    const val SESSION_KEY_REGEX = "^[0-9a-f]{32}$"

    fun fitsBound(text: String): Boolean = text.toByteArray(Charsets.UTF_8).size <= MAX_CONTROL_BYTES
}
