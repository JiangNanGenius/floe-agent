// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import org.json.JSONObject
import java.util.UUID

/** Supplementary result proof only. It never creates a session/grant/owner. */
internal fun sanitizeEnvironmentTransactionReceipt(value: JSONObject?): JSONObject? {
    value ?: return null
    if (value.keys().asSequence().toSet() != setOf("id", "outcome", "snapshotBytes")) return null
    val id = value.opt("id") as? String ?: return null
    if (!runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)) return null
    val outcome = value.opt("outcome") as? String ?: return null
    if (outcome !in setOf("committed", "rolledBack")) return null
    val number = value.opt("snapshotBytes") as? Number ?: return null
    val bytes = number.toString().toLongOrNull()?.takeIf { it in 0..4L * 1024 * 1024 * 1024 } ?: return null
    return JSONObject().put("id", id).put("outcome", outcome).put("snapshotBytes", bytes)
}
