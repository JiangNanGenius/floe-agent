// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive

/** WebView JSON-encodes the JavaScript return value once. The trusted
 * protocol expressions already return JSON text, so remove that transport
 * string envelope exactly once before Swift decodes the untrusted payload.
 * Objects, null and invalid replies retain their original failure behavior.
 */
internal fun browserProtocolReply(raw: String): String {
    val value = runCatching { Json.parseToJsonElement(raw) }.getOrNull()
    return if (value is JsonPrimitive && value.isString) value.content else raw
}
