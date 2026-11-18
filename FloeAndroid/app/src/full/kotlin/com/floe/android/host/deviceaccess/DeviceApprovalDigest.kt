// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.DeviceApprovalAction
import com.floe.android.host.DeviceApprovalIdentity
import com.floe.android.phonecontrol.PhoneControlApprovalTarget
import org.json.JSONArray
import java.security.MessageDigest

/** Digest associates two checked presentations; it is never a device grant. */
internal object DeviceApprovalDigest {
    fun compute(identity: DeviceApprovalIdentity, action: DeviceApprovalAction,
                target: PhoneControlApprovalTarget, revision: Long, targetRevision: Long): String {
        val b = target.bounds
        val canonical = JSONArray().put("floe.device-approval/1")
            .put(identity.taskID.toString()).put(identity.runID.toString()).put(identity.nativeEpoch)
            .put("accessibility").put("$revision:$targetRevision:${target.fenceGeneration}")
            .put(action.observationId).put(action.nodeRef).put(target.windowId).put(target.displayId)
            .put(target.pageGeneration).put(target.fenceGeneration).put(action.action)
            .put(action.direction.orEmpty()).put(action.inputKind.orEmpty()).put(target.packageName)
            .put(target.className).put(target.label)
            .put(JSONArray().put(b.left).put(b.top).put(b.right).put(b.bottom)).toString()
        return MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
