// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.json.JSONObject

/**
 * FULL-only trusted descriptor catalog for the App's phone and Android-system
 * tools.
 *
 * These names, schemas and descriptions live ONLY in the `full` source set.
 * The common/Play core never sees them: Play never binds a platform catalog and
 * therefore registers/advertises nothing. The generic Swift mailbox validates
 * every descriptor again (closed keys, canonical risk/effect, main-run-only,
 * serial, bounded closed schema) before registering it in the ORIGINAL
 * ToolRunnerRegistry.
 *
 * Model-visible results are bounded by the transport contract: a 2048-character
 * summary plus up to eight 192-byte evidence lines. The tools below therefore
 * return a compact digest (page identity + actionable node refs, file/process
 * rows, bounded text previews with byte offsets) instead of pretending to
 * stream an unbounded tree. No raw shell, code-execution or arbitrary-command
 * tool exists here.
 */
internal object DeviceAccessToolCatalog {

    const val PHONE_OBSERVE = "phone.observe"
    const val PHONE_ACT = "phone.act"
    const val PHONE_SCREENSHOT = "phone.screenshot"
    const val SYSTEM_ACCESS_STATUS = "system.access.status"
    const val SYSTEM_FILES_LIST = "system.files.list"
    const val SYSTEM_FILES_READ = "system.files.read"
    const val SYSTEM_FILES_WRITE = "system.files.write"
    const val SYSTEM_FILES_MOVE = "system.files.move"
    const val SYSTEM_FILES_DELETE = "system.files.delete"
    const val SYSTEM_PROCESSES_QUERY = "system.processes.query"
    const val SYSTEM_SERVICES_QUERY = "system.services.query"
    const val SYSTEM_PACKAGES_QUERY = "system.packages.query"
    const val SYSTEM_NETWORK_DIAGNOSTICS = "system.network.diagnostics"
    const val SYSTEM_PACKAGES_FORCE_STOP = "system.packages.forceStop"

    val allNames: Set<String> = linkedSetOf(
        PHONE_OBSERVE, PHONE_ACT, PHONE_SCREENSHOT,
        SYSTEM_ACCESS_STATUS,
        SYSTEM_FILES_LIST, SYSTEM_FILES_READ, SYSTEM_FILES_WRITE,
        SYSTEM_FILES_MOVE, SYSTEM_FILES_DELETE,
        SYSTEM_PROCESSES_QUERY, SYSTEM_SERVICES_QUERY,
        SYSTEM_PACKAGES_QUERY, SYSTEM_NETWORK_DIAGNOSTICS,
        SYSTEM_PACKAGES_FORCE_STOP,
    )

    /** Actual capability ceiling for the SAME live root epoch. */
    data class Availability(
        val accessibilityConnected: Boolean = false,
        val targetPackagesSelected: Boolean = false,
        val screenScopeEnabled: Boolean = false,
        val wholeScreenCaptureConsent: Boolean = false,
        val windowScreenshotCapable: Boolean = false,
        val systemServiceAlive: Boolean = false,
        val fileRootsSelected: Boolean = false,
        val fileWritesAllowed: Boolean = false,
        val packageManagementAllowed: Boolean = false,
    )

    fun availableNames(availability: Availability): Set<String> {
        val result = linkedSetOf<String>()
        // Status is a read-only disclosure of the REAL layer states. It is
        // useful even while everything is off (the model can tell the user
        // exactly what to enable) and grants nothing.
        result += SYSTEM_ACCESS_STATUS
        val phone = availability.accessibilityConnected &&
            availability.targetPackagesSelected
        if (phone) {
            result += PHONE_OBSERVE
            result += PHONE_ACT
            if (availability.screenScopeEnabled &&
                (availability.windowScreenshotCapable ||
                    availability.wholeScreenCaptureConsent)
            ) {
                result += PHONE_SCREENSHOT
            }
        }
        if (availability.systemServiceAlive) {
            result += SYSTEM_PROCESSES_QUERY
            result += SYSTEM_SERVICES_QUERY
            result += SYSTEM_PACKAGES_QUERY
            result += SYSTEM_NETWORK_DIAGNOSTICS
            if (availability.fileRootsSelected) {
                result += SYSTEM_FILES_LIST
                result += SYSTEM_FILES_READ
                if (availability.fileWritesAllowed) {
                    result += SYSTEM_FILES_WRITE
                    result += SYSTEM_FILES_MOVE
                    result += SYSTEM_FILES_DELETE
                }
            }
            if (availability.packageManagementAllowed) {
                result += SYSTEM_PACKAGES_FORCE_STOP
            }
        }
        return result
    }

    /** Strict trusted catalog: all reviewed potential tools, fail-closed mask
     * is published separately by [availableNames] for the same epoch. */
    fun catalogJson(): ByteArray {
        val tools = JSONArray()
        tools.put(phoneObserve())
        tools.put(phoneAct())
        tools.put(phoneScreenshot())
        tools.put(systemAccessStatus())
        tools.put(systemFilesList())
        tools.put(systemFilesRead())
        tools.put(systemFilesWrite())
        tools.put(systemFilesMove())
        tools.put(systemFilesDelete())
        tools.put(systemProcessesQuery())
        tools.put(systemServicesQuery())
        tools.put(systemPackagesQuery())
        tools.put(systemNetworkDiagnostics())
        tools.put(systemPackagesForceStop())
        val root = JSONObject()
            .put("version", 1)
            .put("tools", tools)
        return root.toString().toByteArray(Charsets.UTF_8)
    }

    // ---------------------------------------------------------------- phone

    private fun phoneObserve(): JSONObject = tool(
        name = PHONE_OBSERVE,
        description = "Observe the visible page of the active phone task. " +
            "Returns the observation id, page identity and a bounded list of " +
            "actionable node refs (clickable/editable/scrollable). Password " +
            "fields, secure windows and the lock screen are never read. A " +
            "fresh observation invalidates older refs.",
        schema = schema(
            properties = JSONObject()
                .put("includeInvisible", bool("Include nodes that are not visible.")),
            required = emptyList(),
        ),
        risks = listOf("controlsGUI", "sendsDataToProvider"),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun phoneAct(): JSONObject = tool(
        name = PHONE_ACT,
        description = "Act on one node of the current phone observation. " +
            "Supported actions: click, setText, scroll, swipe, back, home, " +
            "launch. The action is dispatched once, then re-observed; framework " +
            "acceptance is not reported as semantic success. A node ref from an " +
            "expired or replaced observation is refused.",
        schema = schema(
            properties = JSONObject()
                .put("observationId", string("Observation id returned by phone.observe.", 1, 64))
                .put("action", enum(
                    "Action to perform.",
                    listOf("click", "setText", "scroll", "swipe", "back", "home", "launch"),
                ))
                .put("nodeRef", string("Node ref for click/setText/scroll/swipe.", 1, 16))
                .put("text", string("Replacement text for setText (max 2000 characters).", 0, 2000))
                .put("direction", enum(
                    "Direction for scroll or swipe.",
                    listOf("forward", "backward", "up", "down", "left", "right"),
                ))
                .put("packageName", string("Target package for launch.", 1, 255)),
            required = listOf("observationId", "action"),
        ),
        risks = listOf("controlsGUI", "sendsDataToProvider"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun phoneScreenshot(): JSONObject = tool(
        name = PHONE_SCREENSHOT,
        description = "Capture the current page as a real image artifact. " +
            "With observationId the preferred window-scoped capture is used " +
            "where the platform supports it; without it an explicit whole-screen " +
            "capture is attempted only when the user allowed it. Protected, " +
            "password and foreign/overlay windows are refused, never widened.",
        schema = schema(
            properties = JSONObject()
                .put("observationId", string(
                    "Observation to capture (window-scoped where supported).", 0, 64)),
            required = emptyList(),
        ),
        risks = listOf("controlsGUI", "sendsDataToProvider"),
        effect = "readOnly",
        sideEffecting = false,
    )

    // ---------------------------------------------------------- system status

    private fun systemAccessStatus(): JSONObject = tool(
        name = SYSTEM_ACCESS_STATUS,
        description = "Read the actual embedded-ADB and root service state, the " +
            "user-granted file root ids, write ceiling and whether package " +
            "management is allowed. Reports unavailable layers honestly; it " +
            "never changes a permission.",
        schema = schema(properties = JSONObject(), required = emptyList()),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    // ---------------------------------------------------------------- files

    private fun systemFilesList(): JSONObject = tool(
        name = SYSTEM_FILES_LIST,
        description = "List one directory under a user-granted file root. " +
            "Returns at most 24 compact entries (dir|size|path) so the bounded " +
            "result stays readable; narrow the path instead of expecting a full " +
            "recursive tree.",
        schema = schema(
            properties = JSONObject()
                .put("root", string("Granted file root id from system.access.status.", 1, 64))
                .put("path", string("Relative directory path (no absolute paths, no '..').", 0, 512))
                .put("maxEntries", integer("Maximum entries (1-60).", 1, 60)),
            required = listOf("root"),
        ),
        risks = listOf("readsFiles"),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemFilesRead(): JSONObject = tool(
        name = SYSTEM_FILES_READ,
        description = "Read a bounded UTF-8 text preview of one file under a " +
            "user-granted root. The summary is capped at 2048 characters; pass " +
            "the returned next offset to continue paging. Binary content is " +
            "reported by size only, never decoded.",
        schema = schema(
            properties = JSONObject()
                .put("root", string("Granted file root id.", 1, 64))
                .put("path", string("Relative file path.", 1, 512))
                .put("offset", integer("Byte offset to start reading from.", 0, 1_000_000_000))
                .put("maxBytes", integer("Bytes to read (1-16384).", 1, 16_384)),
            required = listOf("root", "path"),
        ),
        risks = listOf("readsFiles"),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemFilesWrite(): JSONObject = tool(
        name = SYSTEM_FILES_WRITE,
        description = "Write UTF-8 text to a new file under a user-granted " +
            "writable root. Existing files are refused unless overwrite is true. " +
            "The service writes atomically and returns the real byte count.",
        schema = schema(
            properties = JSONObject()
                .put("root", string("Granted file root id.", 1, 64))
                .put("path", string("Relative file path.", 1, 512))
                .put("text", string("UTF-8 text to write (max 12000 characters).", 0, 12_000))
                .put("overwrite", bool("Replace an existing file.")),
            required = listOf("root", "path"),
        ),
        risks = listOf("writesFiles"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemFilesMove(): JSONObject = tool(
        name = SYSTEM_FILES_MOVE,
        description = "Move or rename one file under the same user-granted " +
            "writable root. Cross-root moves are refused.",
        schema = schema(
            properties = JSONObject()
                .put("root", string("Granted file root id.", 1, 64))
                .put("from", string("Relative source path.", 1, 512))
                .put("to", string("Relative destination path.", 1, 512))
                .put("overwrite", bool("Replace an existing destination.")),
            required = listOf("root", "from", "to"),
        ),
        risks = listOf("writesFiles", "deletesFiles"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemFilesDelete(): JSONObject = tool(
        name = SYSTEM_FILES_DELETE,
        description = "Delete one file or directory under a user-granted " +
            "writable root. Non-empty directories require recursive=true.",
        schema = schema(
            properties = JSONObject()
                .put("root", string("Granted file root id.", 1, 64))
                .put("path", string("Relative path to delete.", 1, 512))
                .put("recursive", bool("Delete a non-empty directory recursively.")),
            required = listOf("root", "path"),
        ),
        risks = listOf("deletesFiles"),
        effect = "mutating",
        sideEffecting = true,
    )

    // ------------------------------------------------------------- processes

    private fun systemProcessesQuery(): JSONObject = tool(
        name = SYSTEM_PROCESSES_QUERY,
        description = "Query running processes through the live Floe system " +
            "service. Returns at most 24 compact rows (pid|uid|name).",
        schema = schema(
            properties = JSONObject()
                .put("filter", string("Optional case-insensitive name filter.", 0, 128))
                .put("maxEntries", integer("Maximum entries (1-200).", 1, 200)),
            required = emptyList(),
        ),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemServicesQuery(): JSONObject = tool(
        name = SYSTEM_SERVICES_QUERY,
        description = "Query Android services through the live Floe system " +
            "service. Returns at most 24 compact rows.",
        schema = schema(
            properties = JSONObject()
                .put("maxEntries", integer("Maximum entries (1-200).", 1, 200)),
            required = emptyList(),
        ),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemPackagesQuery(): JSONObject = tool(
        name = SYSTEM_PACKAGES_QUERY,
        description = "Query installed packages through the live Floe system " +
            "service. Returns at most 24 compact rows (package|uid|version).",
        schema = schema(
            properties = JSONObject()
                .put("packageName", string("Optional exact package filter.", 0, 255))
                .put("includeSystem", bool("Include system packages."))
                .put("maxEntries", integer("Maximum entries (1-200).", 1, 200)),
            required = emptyList(),
        ),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemNetworkDiagnostics(): JSONObject = tool(
        name = SYSTEM_NETWORK_DIAGNOSTICS,
        description = "Read interfaces, addresses, routes and active transports " +
            "through the live Floe system service. Bounded, read-only.",
        schema = schema(properties = JSONObject(), required = emptyList()),
        risks = listOf("networkAccess"),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemPackagesForceStop(): JSONObject = tool(
        name = SYSTEM_PACKAGES_FORCE_STOP,
        description = "Force-stop one user package through the live Floe system " +
            "service. Requires the user's explicit app-management ceiling and an " +
            "approved task grant; Floe's own package is always refused.",
        schema = schema(
            properties = JSONObject()
                .put("packageName", string("Package to stop.", 1, 255))
                .put("userId", integer("Android user id (default 0).", 0, 999)),
            required = listOf("packageName"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    // ------------------------------------------------------------- builders

    private fun tool(
        name: String,
        description: String,
        schema: JSONObject,
        risks: List<String>,
        effect: String,
        sideEffecting: Boolean,
    ): JSONObject = JSONObject()
        .put("name", name)
        .put("description", description)
        .put("schema", schema)
        .put("riskLabels", JSONArray(risks))
        .put("effect", effect)
        .put("isSideEffecting", sideEffecting)
        // The Android device is not a Linux host/workspace scope; authority is
        // the canonical approval + App capability ceiling.
        .put("hostScope", false)
        .put("executionBoundary", "mainRunOnly")
        .put("supportsConcurrentBatchDispatch", false)

    private fun schema(
        properties: JSONObject,
        required: List<String>,
    ): JSONObject = JSONObject()
        .put("type", "object")
        .put("properties", properties)
        .put("required", JSONArray(required))
        .put("additionalProperties", false)

    private fun string(description: String, minLength: Int, maxLength: Int): JSONObject =
        JSONObject()
            .put("type", "string")
            .put("description", description)
            .put("minLength", minLength)
            .put("maxLength", maxLength)

    private fun enum(description: String, values: List<String>): JSONObject =
        JSONObject()
            .put("type", "string")
            .put("description", description)
            .put("enum", JSONArray(values))

    private fun integer(description: String, minimum: Int, maximum: Int): JSONObject =
        JSONObject()
            .put("type", "integer")
            .put("description", description)
            .put("minimum", minimum)
            .put("maximum", maximum)

    private fun bool(description: String): JSONObject =
        JSONObject()
            .put("type", "boolean")
            .put("description", description)
}
