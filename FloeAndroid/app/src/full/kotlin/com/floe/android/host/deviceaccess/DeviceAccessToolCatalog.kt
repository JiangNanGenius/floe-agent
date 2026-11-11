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
    const val SYSTEM_PACKAGES_STAGED = "system.packages.staged"
    const val SYSTEM_PACKAGES_STAGE = "system.packages.stage"
    const val SYSTEM_PACKAGES_INSTALL = "system.packages.install"
    const val SYSTEM_PACKAGES_UNINSTALL = "system.packages.uninstall"
    const val SYSTEM_PACKAGES_SET_ENABLED = "system.packages.setEnabled"
    const val SYSTEM_PACKAGES_REMOVE_FOR_USER = "system.packages.removeForUser"
    const val SYSTEM_PACKAGES_RESTORE = "system.packages.restore"
    const val SYSTEM_PERMISSIONS_QUERY = "system.permissions.query"
    const val SYSTEM_PERMISSIONS_MANAGE = "system.permissions.manage"
    const val SYSTEM_APPOPS_QUERY = "system.appOps.query"
    const val SYSTEM_APPOPS_MANAGE = "system.appOps.manage"
    const val SYSTEM_SETTINGS_READ = "system.settings.read"
    const val SYSTEM_SETTINGS_WRITE = "system.settings.write"

    /**
     * The ABI's six-name closed list for settings.advancedSystemAllowedTools.
     * The reserved permission/AppOps names stay unpublished until those
     * packets ship; only names in this set may persist, be admitted or gate
     * discovery. This packet publishes only system.settings.write.
     */
    val ADVANCED_ABI_TOOL_NAMES: Set<String> = setOf(
        SYSTEM_PACKAGES_SET_ENABLED,
        SYSTEM_PACKAGES_REMOVE_FOR_USER,
        SYSTEM_PACKAGES_RESTORE,
        "system.permissions.manage",
        "system.appOps.manage",
        SYSTEM_SETTINGS_WRITE,
    )

    val allNames: Set<String> = linkedSetOf(
        PHONE_OBSERVE, PHONE_ACT, PHONE_SCREENSHOT,
        SYSTEM_ACCESS_STATUS,
        SYSTEM_FILES_LIST, SYSTEM_FILES_READ, SYSTEM_FILES_WRITE,
        SYSTEM_FILES_MOVE, SYSTEM_FILES_DELETE,
        SYSTEM_PROCESSES_QUERY, SYSTEM_SERVICES_QUERY,
        SYSTEM_PACKAGES_QUERY, SYSTEM_NETWORK_DIAGNOSTICS,
        SYSTEM_PACKAGES_FORCE_STOP,
        SYSTEM_PACKAGES_STAGED, SYSTEM_PACKAGES_STAGE,
        SYSTEM_PACKAGES_INSTALL, SYSTEM_PACKAGES_UNINSTALL,
        SYSTEM_PACKAGES_SET_ENABLED,
        SYSTEM_PACKAGES_REMOVE_FOR_USER, SYSTEM_PACKAGES_RESTORE,
        SYSTEM_PERMISSIONS_QUERY, SYSTEM_PERMISSIONS_MANAGE,
        SYSTEM_APPOPS_QUERY, SYSTEM_APPOPS_MANAGE,
        SYSTEM_SETTINGS_READ, SYSTEM_SETTINGS_WRITE,
        )

    /** Actual capability ceiling for the SAME live root epoch. */
    data class Availability(
        val accessibilityConnected: Boolean = false,
        val targetPackagesSelected: Boolean = false,
        /**
         * The phone module can capture at all on this platform (API 30+).
         *
         * This is the POTENTIAL capability, not the task's screen consent:
         * like task arming for [PHONE_OBSERVE]/[PHONE_ACT], the per-call task
         * screen scope, whole-screen consent, observation/window fence and
         * arm state are all enforced by the host when the tool is invoked.
         * Discovery must not depend on those mutable grants: the runtime
         * freezes what the run was offered, so a grant made while a run is
         * live would otherwise offer a name the frozen catalog refuses.
         */
        val screenCaptureSupported: Boolean = false,
        val systemServiceAlive: Boolean = false,
        val fileRootsSelected: Boolean = false,
        val fileWritesAllowed: Boolean = false,
        val packageManagementAllowed: Boolean = false,
        /**
         * The ONE shared advanced-system master (durable). This packet's
         * three app-state tools require it plus the base management ceiling
         * and a non-empty selected target set; later permission/AppOps/
         * settings packets reuse the same master and selection. Discovery
         * never precedes the real ceilings.
         */
        val advancedSystemManagementAllowed: Boolean = false,
        /**
         * Allowed advanced tool names from the ABI's six-name closed list.
         * Only the three shipped app-state names can appear today; the
         * reserved permission/AppOps/settings names are never published or
         * given placeholder UI.
         */
        val advancedSystemAllowedTools: Set<String> = emptySet(),
        /** Selected installed-app target ceiling for the advanced group. */
        val advancedSystemTargetsSelected: Boolean = false,
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
            // Potential capability, not a task grant. The device's capture
            // support alone decides discoverability; the host refuses the
            // call with screen_scope_off / whole_screen_consent_required /
            // window_screenshot_unsupported / phone_arm_required unless the
            // live task really holds that authority.
            if (availability.screenCaptureSupported) {
                result += PHONE_SCREENSHOT
            }
        }
        if (availability.systemServiceAlive) {
            result += SYSTEM_PROCESSES_QUERY
            result += SYSTEM_SERVICES_QUERY
            result += SYSTEM_PACKAGES_QUERY
            result += SYSTEM_NETWORK_DIAGNOSTICS
            // Closed settings read rides the same read-only ceiling as the
            // other system queries (temporary-chat rules unchanged).
            result += SYSTEM_SETTINGS_READ
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
                result += SYSTEM_PACKAGES_INSTALL
                result += SYSTEM_PACKAGES_UNINSTALL
                if (availability.advancedSystemManagementAllowed &&
                    availability.advancedSystemTargetsSelected
                ) {
                    // The durable allowed-tools set stores the ABI's exact
                    // full tool names; only the three shipped app-state
                    // names can pass here today.
                    if (SYSTEM_PACKAGES_SET_ENABLED in availability.advancedSystemAllowedTools) {
                        result += SYSTEM_PACKAGES_SET_ENABLED
                    }
                    if (SYSTEM_PACKAGES_REMOVE_FOR_USER in availability.advancedSystemAllowedTools) {
                        result += SYSTEM_PACKAGES_REMOVE_FOR_USER
                    }
                    if (SYSTEM_PACKAGES_RESTORE in availability.advancedSystemAllowedTools) {
                        result += SYSTEM_PACKAGES_RESTORE
                    }
                    // This packet's two query descriptors ship with the
                    // advanced master and a non-empty selected target
                    // ceiling (already implied by this block); the two
                    // managers additionally require their exact ABI name in
                    // the durable allowed-tools set. The reserved
                    // system.settings.write name is never published.
                    result += SYSTEM_PERMISSIONS_QUERY
                    result += SYSTEM_APPOPS_QUERY
                    if (SYSTEM_PERMISSIONS_MANAGE in availability.advancedSystemAllowedTools) {
                        result += SYSTEM_PERMISSIONS_MANAGE
                    }
                    if (SYSTEM_APPOPS_MANAGE in availability.advancedSystemAllowedTools) {
                        result += SYSTEM_APPOPS_MANAGE
                    }
                }
                // The closed settings write needs the SAME base management
                // ceiling plus the advanced master and its own ABI name; it
                // has no package-target dimension, so it never requires the
                // selected-target ceiling the app-state group needs.
                if (availability.advancedSystemManagementAllowed &&
                    SYSTEM_SETTINGS_WRITE in availability.advancedSystemAllowedTools
                ) {
                    result += SYSTEM_SETTINGS_WRITE
                }
            }
            // The staged-APK list is App-local bookkeeping (zero privilege):
            // it is offered with any live system service so the model can plan
            // an install before the management ceiling is even enabled.
            result += SYSTEM_PACKAGES_STAGED
            // Staging moves task-owned (workspace) or user-granted (file
            // root) bytes into verified App/service staging; discovery only
            // needs a live system layer, while the actual stage call carries
            // the management-ceiling grant like install/uninstall.
            result += SYSTEM_PACKAGES_STAGE
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
        tools.put(systemPackagesStaged())
        tools.put(systemPackagesStage())
        tools.put(systemPackagesInstall())
        tools.put(systemPackagesUninstall())
        tools.put(systemPackagesSetEnabled())
        tools.put(systemPackagesRemoveForUser())
        tools.put(systemPackagesRestore())
        tools.put(systemPermissionsQuery())
        tools.put(systemPermissionsManage())
        tools.put(systemAppOpsQuery())
        tools.put(systemAppOpsManage())
        tools.put(systemSettingsRead())
        tools.put(systemSettingsWrite())
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
            "fresh observation invalidates older refs. Pass the returned " +
            "observation= id as observationId on the next phone.act: every " +
            "phone.act action except launch requires it.",
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
        description = "Act on the latest phone observation: every action except launch requires " +
            "observationId, the id from the observation= line of the newest phone.observe result in " +
            "this run; after an approval wait, a takeover or any screen change, observe again first. " +
            "Only action=launch may omit observationId: launch an authorized app with action=launch " +
            "and packageName, and the existing launch path obtains current navigation state after " +
            "approval. If a call fails with phone_observation_required, call phone.observe again and " +
            "act on its new id; never invent or reuse an older id. " +
            "Supported actions: click, setText, scroll, swipe, back, home, " +
            "launch. The action is dispatched once, then re-observed; framework " +
            "acceptance is not reported as semantic success. A node ref from an " +
            "expired or replaced observation is refused. Use only refs from the latest " +
            "actual observation in this run, never from narrative or history. Node flags " +
            "c/e/s/p indicate click/setText/scroll/protected field; '-' is read-only. A label child " +
            "is not automatically clickable; use its returned actionable parent ref. " +
            "An empty editable input is still listed as [empty input]. A p field never shows " +
            "its contents and refuses ordinary text: to fill one with a credential the user " +
            "already provided in this conversation, send action=setText with sensitiveText " +
            "(setText needs exactly one of text or sensitiveText, never both; an empty " +
            "string clears the field). Persisted setText input is redacted for " +
            "every field, an accepted fill is never read back, and an interrupted fill is " +
            "never silently replayed. Screenshots stay refused while any password field is " +
            "visible. Never search the screen, files or other apps for a password.",
        schema = schema(
            properties = JSONObject()
                .put("observationId", string("Required for every action except launch: the id from the latest phone.observe observation= line. Omit only for action=launch; back and home also require it.", 1, 64))
                .put("action", enum(
                    "Action to perform.",
                    listOf("click", "setText", "scroll", "swipe", "back", "home", "launch"),
                ))
                .put("nodeRef", string("Node ref for click/setText/scroll/swipe.", 1, 16))
                .put("text", string(
                    "Ordinary replacement text for setText (max 2000 characters). Refused on a protected (p) field; use sensitiveText there. The value is redacted from persisted arguments.", 0, 2000,
                ))
                .put("sensitiveText", string(
                    "User-provided credential for a protected (p) field, used instead of text on action=setText and never together with it. Dispatched once, never read back, redacted from every durable record and non-replayable after interruption.", 0, 2000,
                ))
                .put("direction", enum(
                    "Direction for scroll or swipe.",
                    listOf("forward", "backward", "up", "down", "left", "right"),
                ))
                .put("packageName", string("Target package for launch.", 1, 255)),
            required = listOf("action"),
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
        description = "Read actual Android phone UI readiness (accessibility connection, " +
            "selected app scope and user stop), embedded-ADB and root service state, the " +
            "user-granted file root ids, write ceiling and whether package " +
            "management is allowed. Reports unavailable layers honestly; it " +
            "never changes a permission. Phone UI readiness is independent of system " +
            "queries: an authorized live ADB/root service can query the system while " +
            "accessibility is disabled. If phone tools are absent, check this status " +
            "and ask the user to complete Settings > Phone. VNC controls a remote " +
            "or Linux desktop, not the Android phone screen.",
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
            "service. Returns at most 24 compact rows (package|uid|version). " +
            "With includeUninstalled, system-image packages that are removed " +
            "for the current user are included too (enabled=false).",
        schema = schema(
            properties = JSONObject()
                .put("packageName", string("Optional exact package filter.", 0, 255))
                .put("includeSystem", bool("Include system packages."))
                .put("includeUninstalled", bool(
                    "Include system-image packages not installed for the current user."))
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
            "service. Inside the user's enabled app-management ceiling an " +
            "admitted task is auto-approved; Floe's own package is always " +
            "refused.",
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

    private fun systemPackagesStaged(): JSONObject = tool(
        name = SYSTEM_PACKAGES_STAGED,
        description = "List the APKs currently staged for installation: opaque " +
            "staged id, file name, byte size, content digest prefix and the " +
            "package name read from the archive. Entries come from manual user " +
            "picks, system.packages.stage workspace transfers or granted file " +
            "roots. Reading this list is App-local and changes nothing; the " +
            "ids are the only legal system.packages.install targets.",
        schema = schema(properties = JSONObject(), required = emptyList()),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemPackagesStage(): JSONObject = tool(
        name = SYSTEM_PACKAGES_STAGE,
        description = "Stage one or more APKs (at most 8) so system.packages.install can use them, without a manual file picker. Two trusted origins: origin=workspace with a path relative to the current task's resolved Linux workspace (only real task-owned files resolve; absolute paths, '..' and non-APK files are refused), or origin=fileRoot with a granted root id from system.access.status plus a relative path inside that root. Staging copies bytes into verified App/service staging and returns the opaque staged id (digest-bound), byte size and archive package name per item; it never installs anything. Requires the user's app-management ceiling for the stage call itself.",
        schema = schema(
            properties = JSONObject()
                .put("sources", JSONObject()
                    .put("type", "array")
                    .put("description", "Ordered APK sources (1-8).")
                    .put("minItems", 1)
                    .put("maxItems", 8)
                    .put("items", JSONObject()
                        .put("type", "object")
                        .put("required", JSONArray(listOf("origin", "path")))
                        .put("additionalProperties", false)
                        .put("properties", JSONObject()
                            .put("origin", enum(
                                "Where the APK bytes come from.",
                                listOf("workspace", "fileRoot"),
                            ))
                            .put("path", string(
                                "Relative file path ending in .apk (no absolute paths, no '..').",
                                1, 512,
                            ))
                            .put("root", string(
                                "Granted file root id (origin=fileRoot only).", 1, 64,
                            ))))),
            required = listOf("sources"),
        ),
        risks = listOf("writesFiles"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemPackagesInstall(): JSONObject = tool(
        name = SYSTEM_PACKAGES_INSTALL,
        description = "Install one or more staged APKs (at most 8) by the staged ids returned from system.packages.stage or system.packages.staged. Each item is streamed by the privileged service to the real package manager and reports a definitive per-item installed/failed outcome from a post-install read-back of the same user. Requires the user's app-management ceiling; protected/system identities are refused per item. Cancelling the run skips the remaining items.",
        schema = schema(
            properties = JSONObject()
                .put("stagedIds", stringArray(
                    "Ordered staged ids (1-8).", 1, 8))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("stagedIds"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemPackagesUninstall(): JSONObject = tool(
        name = SYSTEM_PACKAGES_UNINSTALL,
        description = "Uninstall one or more third-party packages (at most 8) " +
            "for a user through the live Floe system service. Each item reports " +
            "a definitive per-item uninstalled/failed outcome from a " +
            "post-uninstall read-back. Requires the user's app-management " +
            "ceiling; Floe's own package and system packages are refused per " +
            "item. Cancelling the run skips the remaining items.",
        schema = schema(
            properties = JSONObject()
                .put("packages", stringArray("Ordered package names (1-8).", 1, 8))
                .put("userId", integer("Android user id (default 0).", 0, 999)),
            required = listOf("packages"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    // ------------------------------------------------------- app-state tools

    /**
     * The three shipped advanced app-state tool names. The durable
     * allowed-tools ceiling stores these exact ABI names; the reserved
     * permission/AppOps/settings names stay unpublished with no UI.
     */
    val SHIPPED_ADVANCED_TOOLS: Set<String> = setOf(
        SYSTEM_PACKAGES_SET_ENABLED,
        SYSTEM_PACKAGES_REMOVE_FOR_USER,
        SYSTEM_PACKAGES_RESTORE,
        SYSTEM_PERMISSIONS_MANAGE,
        SYSTEM_APPOPS_MANAGE,
        SYSTEM_SETTINGS_WRITE,
    )

    private fun systemPackagesSetEnabled(): JSONObject = tool(
        name = SYSTEM_PACKAGES_SET_ENABLED,
        description = "Enable, disable or disable-user one or more selected installed apps (at most 8) for the current Android profile through the live Floe system service. Only apps the user selected in Settings are eligible; Floe itself, platform/security essentials and the current launcher, input method or dialer are always refused. Each item reports a definitive per-item outcome from a post-operation PackageManager read-back: an OS refusal is a real failure, never reported as success. Requires the user's app-management ceiling and the advanced app-state switch.",
        schema = schema(
            properties = JSONObject()
                .put("packages", stringArray("Ordered package names (1-8).", 1, 8))
                .put("state", enum(
                    "Requested enabled state.",
                    listOf("enable", "disable", "disable-user"),
                ))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("packages", "state"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemPackagesRemoveForUser(): JSONObject = tool(
        name = SYSTEM_PACKAGES_REMOVE_FOR_USER,
        description = "Remove one or more selected noncritical preinstalled apps (at most 8) for the current Android user only. The system image and existing user data stay intact (-k); system.packages.restore can bring the app back. Third-party packages are refused per item (use system.packages.uninstall); Floe, platform/security essentials and current launcher/input/dialer apps are always refused. Each item reports a definitive per-item removed/failed outcome from a post-operation read-back for the same user. Requires the user's app-management ceiling and the advanced app-state switch.",
        schema = schema(
            properties = JSONObject()
                .put("packages", stringArray("Ordered package names (1-8).", 1, 8))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("packages"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemPackagesRestore(): JSONObject = tool(
        name = SYSTEM_PACKAGES_RESTORE,
        description = "Restore one or more selected preinstalled apps (at most 8) that were previously removed for the current Android user, using the intact system image (pm install-existing). Only system-image packages the user selected in Settings are eligible; each item reports a definitive per-item restored/failed outcome from a post-operation presence read-back for the same user. Requires the user's app-management ceiling and the advanced app-state switch.",
        schema = schema(
            properties = JSONObject()
                .put("packages", stringArray("Ordered package names (1-8).", 1, 8))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("packages"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    // --------------------------------------------- permission/appops tools

    private fun systemPermissionsQuery(): JSONObject = tool(
        name = SYSTEM_PERMISSIONS_QUERY,
        description = "Read the real manifest-declared permissions, protection levels and granted state for one app the user selected in Settings, for the current Android profile, through the live Floe system service. Read-only: it changes nothing and never touches apps outside the selected targets. An AppOps change does not grant a manifest permission and vice versa.",
        schema = schema(
            properties = JSONObject()
                .put("packageName", string("Selected package to inspect.", 3, 255))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("packageName"),
        ),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemPermissionsManage(): JSONObject = tool(
        name = SYSTEM_PERMISSIONS_MANAGE,
        description = "Grant or revoke one or more manifest-declared runtime or development permissions (at most 8 items) for selected apps of the current Android profile through the real package manager. Each item reports grantedBefore/requested/grantedAfter from an independent post-pm read-back of the same user: an OS refusal (signature, fixed, admin or platform permission, undeclared permission, or a package sharing its UID with another app) is a real per-item failure, never reported as success. Requires the user's app-management ceiling, the advanced master, and the permissions.manage category.",
        schema = schema(
            properties = JSONObject()
                .put("items", JSONObject()
                    .put("type", "array")
                    .put("description", "Ordered permission items (1-8).")
                    .put("minItems", 1)
                    .put("maxItems", 8)
                    .put("items", JSONObject()
                        .put("type", "object")
                        .put("required", JSONArray(listOf("packageName", "permission", "action")))
                        .put("additionalProperties", false)
                        .put("properties", JSONObject()
                            .put("packageName", string("Selected package.", 3, 255))
                            .put("permission", string(
                                "Manifest permission name, e.g. android.permission.CAMERA.",
                                3, 255,
                            ))
                            .put("action", enum(
                                "Requested grant state.",
                                listOf("grant", "revoke"),
                            )))))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("items"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    private fun systemAppOpsQuery(): JSONObject = tool(
        name = SYSTEM_APPOPS_QUERY,
        description = "Read the closed-catalog AppOps modes (camera, microphone, notification, coarse/fine location, storage read/write, overlay, write-settings, usage access, background run [legacy and modern ops], install packages) for one selected app of the current Android profile. Each row reports the per-package override, the UID-level mode and the platform default separately, plus the effective mode; 'default' means platform behavior applies, never a hidden allow. Read-only. Requires the user's app-management ceiling, the advanced master and a selected target.",
        schema = schema(
            properties = JSONObject()
                .put("packageName", string("Selected package to inspect.", 3, 255))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("packageName"),
        ),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemAppOpsManage(): JSONObject = tool(
        name = SYSTEM_APPOPS_MANAGE,
        description = "Set one or more closed-catalog AppOps modes (at most 8 items: allow, ignore, deny, default, foreground where the OS supports it) for selected apps of the current Android profile through the real appops command. Each item defaults to the legacy package scope (package-scoped --user form); an item may set scope=uid to write the UID-level mode instead, which changes the UID-level row directly; a package override may be masked by an explicit UID mode, so inspect the effective mode as well. UID scope uses the same app-management authorization and requires a live service that advertises the capability, and a uniquely owned UID of the selected target; shared UIDs and protected apps are refused per item, the UID is resolved by the service (never supplied here), and success is proven on the requested scope's read-back row. Each item captures the restorable before state (override/UID/default separately), the requested mode and the observed read-back; unparseable read-back is a failure, never a success. AppOps changes do not grant manifest permissions. Requires the user's app-management ceiling, the advanced master, and the appOps.manage category.",
        schema = schema(
            properties = JSONObject()
                .put("items", JSONObject()
                    .put("type", "array")
                    .put("description", "Ordered AppOps items (1-8).")
                    .put("minItems", 1)
                    .put("maxItems", 8)
                    .put("items", JSONObject()
                        .put("type", "object")
                        .put("required", JSONArray(listOf("packageName", "operation", "mode")))
                        .put("additionalProperties", false)
                        .put("properties", JSONObject()
                            .put("packageName", string("Selected package.", 3, 255))
                            .put("operation", enum(
                                "Closed AppOps catalog operation.",
                                listOf(
                                    "camera", "microphone", "notification",
                                    "location-coarse", "location-fine",
                                    "storage-read", "storage-write",
                                    "overlay", "write-settings", "usage-access",
                                    "background-run", "background-run-any",
                                    "install-packages",
                                ),
                            ))
                            .put("mode", enum(
                                "Requested mode. 'default' restores platform/UID behavior.",
                                listOf("allow", "ignore", "deny", "default", "foreground"),
                            ))
                            .put("scope", enum(
                                "Write scope: 'package' (default, per-package override) or 'uid' (UID-level mode for a uniquely owned UID of the selected target; uses the same app-management authorization and requires a live service that advertises it).",
                                listOf("package", "uid"),
                            )))))
                .put("userId", integer("Android user id (default 0 = current).", 0, 999)),
            required = listOf("items"),
        ),
        risks = listOf("modifiesRemoteSystem"),
        effect = "mutating",
        sideEffecting = true,
    )

    // ---------------------------------------------------------- settings

    private fun systemSettingsRead(): JSONObject = tool(
        name = SYSTEM_SETTINGS_READ,
        description = "Read one closed device setting through the live Floe " +
            "system service: screen brightness, brightness mode, auto-rotate, " +
            "rotation, screen-off timeout, sound effects or haptic feedback " +
            "(system namespace, exact current user), or one of the three " +
            "device-wide animation scales (global namespace). Values are " +
            "stored Settings-provider results: absent keys report " +
            "present=false; a stored value is not proof the manufacturer " +
            "immediately honored an effect. Read-only.",
        schema = schema(
            properties = JSONObject()
                .put("namespace", enum("Settings namespace.", listOf("system", "global")))
                .put("key", string("Closed setting key for the namespace.", 1, 64)),
            required = listOf("namespace", "key"),
        ),
        risks = emptyList(),
        effect = "readOnly",
        sideEffecting = false,
    )

    private fun systemSettingsWrite(): JSONObject = tool(
        name = SYSTEM_SETTINGS_WRITE,
        description = "Apply one bounded typed batch of closed device setting " +
            "changes (at most 8) through the live Floe system service: " +
            "screen brightness (0-255), brightness mode, auto-rotate, " +
            "rotation (0-3), screen-off timeout (15000-1800000 ms), sound " +
            "effects or haptic feedback (system namespace, exact current " +
            "user), or the device-wide animation scales (global, 0-10). Every " +
            "item reports the real old value (absence included), the " +
            "requested value and the stored read-back value; OEM refusals or " +
            "clamps are reported as failures, never fabricated. Cancelling " +
            "the run skips the remaining items and keeps the completed " +
            "outcomes. Requires the user's app-management ceiling plus the " +
            "advanced system switch with this tool selected.",
        schema = schema(
            properties = JSONObject()
                .put("changes", JSONObject()
                    .put("type", "array")
                    .put("description", "Ordered setting changes (1-8).")
                    .put("minItems", 1)
                    .put("maxItems", 8)
                    .put("items", JSONObject()
                        .put("type", "object")
                        .put("required", JSONArray(listOf("namespace", "key", "action")))
                        .put("additionalProperties", false)
                        .put("properties", JSONObject()
                            .put("namespace", enum(
                                "Settings namespace.",
                                listOf("system", "global"),
                            ))
                            .put("key", string(
                                "Closed setting key for the namespace.", 1, 64,
                            ))
                            .put("action", enum(
                                "put stores value; delete removes the key (only to restore an originally-absent value).",
                                listOf("put", "delete"),
                            ))
                            .put("value", string(
                                "Decimal value for put: whole numbers for system keys; 0-10 with up to three decimals for global scales.",
                                1, 16,
                            ))))),
            required = listOf("changes"),
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

    private fun stringArray(description: String, minItems: Int, maxItems: Int): JSONObject =
        JSONObject()
            .put("type", "array")
            .put("description", description)
            .put("minItems", minItems)
            .put("maxItems", maxItems)
            .put("items", JSONObject()
                .put("type", "string")
                .put("minLength", 1)
                .put("maxLength", 255))

    private fun bool(description: String): JSONObject =
        JSONObject()
            .put("type", "boolean")
            .put("description", description)
}
