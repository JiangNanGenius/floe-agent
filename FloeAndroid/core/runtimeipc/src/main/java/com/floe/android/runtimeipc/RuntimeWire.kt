// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import org.json.JSONObject
import org.json.JSONTokener
import java.util.UUID

/** Only control and bounded pages cross Binder. No provider credentials. */
object RuntimeWire {
    const val VERSION = 1
    const val DESCRIPTOR = "com.floe.android.runtime.Control.v1"
    const val EXCHANGE = android.os.IBinder.FIRST_CALL_TRANSACTION
    const val MAX_JSON_BYTES = 65_536
    // Parcel strings are UTF-16; leave bounded space for the interface token.
    const val MAX_PARCEL_BYTES = MAX_JSON_BYTES * 2 + 1_024
    // G03-R3 additive v1: `runtimeWorkspaceCopies.clear` is the trusted-host
    // cleanup control (typed Core->runtime-UID workspace-copy wipe lane). It
    // is NOT a model tool and never appears in any model-facing catalog.
    const val CLEANUP = "runtimeWorkspaceCopies.clear"
    // G03-R3 additive: the two workspace preflight controls are dedicated
    // AUTHENTICATED internal host controls for the first-use NON-EXECUTING
    // round trip (grant-bound file mirroring only). They are NOT
    // shell.start, never carry a command, and never appear in any model
    // tool catalog. (Merge note for Main: union with the cleanup lane's
    // `runtimeWorkspaceCopies.clear` when both land on the same live file.)
    const val PREFLIGHT = "workspace.preflight"
    const val PREFLIGHT_CANCEL = "workspace.preflight.cancel"
    // G07.3A additive v1: bounded READ-ONLY live guest file snapshot and the
    // deferred workspace export status. Neither mutates a workspace, exports
    // draft bytes, closes a terminal nor appears in a model tool catalog.
    const val FILES_TREE = "workspace.files.tree"
    const val FILES_READ = "workspace.files.read"
    const val EXPORT_STATUS = "workspace.exportStatus"
    val operations = setOf("status", "request.status", "install.start", "install.cancel", "install.status",
        "environment.list", "shell.start", "shell.poll", "shell.input", "shell.resize", "shell.cancel",
        CLEANUP, PREFLIGHT, PREFLIGHT_CANCEL, FILES_TREE, FILES_READ, EXPORT_STATUS)

    data class Request(val id: String, val operation: String, val payload: JSONObject)

    fun decode(text: String): Request {
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_JSON_BYTES) { "Runtime request too large" }
        val objectValue = objectValue(text)
        require(objectValue.keys().asSequence().toSet() == setOf("version", "id", "operation", "payload"))
        require(objectValue.get("version") == VERSION)
        val id = objectValue.getString("id")
        require(UUID.fromString(id).toString() == id)
        val operation = objectValue.getString("operation")
        require(operation in operations) { "Unknown runtime operation" }
        return Request(id, operation, objectValue.getJSONObject("payload"))
    }

    fun encode(operation: String, payload: JSONObject = JSONObject(), requestID: String = UUID.randomUUID().toString()): String {
        require(operation in operations)
        require(UUID.fromString(requestID).toString() == requestID)
        return bounded(JSONObject().put("version", VERSION).put("id", requestID)
            .put("operation", operation).put("payload", payload).toString())
    }

    fun reply(request: Request, result: JSONObject): String = bounded(
        JSONObject().put("version", VERSION).put("id", request.id).put("ok", true)
            .put("result", result).toString())

    fun failure(request: Request, code: String): String = bounded(
        JSONObject().put("version", VERSION).put("id", request.id).put("ok", false)
            .put("code", code).toString())

    fun bounded(text: String): String {
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_JSON_BYTES)
        return text
    }

    fun verifyReply(request: Request, text: String): JSONObject {
        val reply = objectValue(bounded(text))
        require(reply.get("version") == VERSION && reply.getString("id") == request.id)
        require(reply.get("ok") is Boolean)
        return reply
    }

    private fun objectValue(text: String): JSONObject {
        // Bound nesting BEFORE invoking Android's recursive JSON parser.
        var depth = 0
        var quoted = false
        var escaped = false
        for (character in text) {
            if (quoted) {
                if (escaped) escaped = false
                else if (character == '\\') escaped = true
                else if (character == '"') quoted = false
            } else when (character) {
                '"' -> quoted = true
                '{', '[' -> { depth++; require(depth <= 32) }
                '}', ']' -> { depth--; require(depth >= 0) }
            }
        }
        require(!quoted && depth == 0)
        val tokener = JSONTokener(text)
        val value = tokener.nextValue()
        require(value is JSONObject && tokener.nextClean() == '\u0000')
        return value
    }
}
