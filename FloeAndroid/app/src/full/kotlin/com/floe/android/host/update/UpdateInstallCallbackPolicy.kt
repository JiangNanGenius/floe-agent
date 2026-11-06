// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

/** Android 13 can send a child's permission request through the parent's
 * IntentSender. Only that recorded child may request confirmation; terminal
 * results still belong to the parent transaction, never an individual child. */
internal object UpdateInstallCallbackPolicy {
    fun owner(record: PendingInstall?, callbackOwnerID: Int, reportedID: Int,
              pendingUserAction: Boolean): Int? {
        if (record == null || callbackOwnerID <= 0 || reportedID <= 0 ||
            record.sessionID != callbackOwnerID) return null
        if (reportedID == record.sessionID) return record.sessionID
        return record.sessionID.takeIf {
            pendingUserAction && record.runtime != null && reportedID in record.childSessionIDs
        }
    }
}
