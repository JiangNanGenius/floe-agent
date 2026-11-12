// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import android.os.Bundle
import com.floe.android.rootsystem.FileEntry
import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.InterfaceInfo
import com.floe.android.rootsystem.NetworkDiagnostics
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.PackageManagementReceipt
import com.floe.android.rootsystem.PackageQuery
import com.floe.android.rootsystem.PackageRecord
import com.floe.android.rootsystem.ProcessRecord
import com.floe.android.rootsystem.RouteInfo
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.ServiceRecord
import com.floe.android.rootsystem.SystemOperation

/**
 * Closed key set and bounded codecs for [IFloeSystemService]. Every Bundle is
 * built here, never from model output. Limits mirror the App-side bounds so a
 * compromised client cannot force an unbounded server allocation.
 */
object BinderProtocol {

    /**
     * Wire evolution marker.
     *
     * Released build 108 already carried VERSION=3, so the v4 UI transactions
     * are a genuinely new protocol revision (the old "wire 3 never shipped"
     * comments in earlier additions are stale history and must not be reused
     * as a reason to keep the marker unchanged). A live service that answers
     * describe() with an older version is a stale Floe-owned helper: the
     * ownership policy stops and replaces it (never adopts it) through its
     * pre-v4 stopOwnedService position, even when the installed APK
     * versionCode is unchanged, so an old parcel shape can never serve the
     * new transactions.
     *
     * Transaction-position contract (verified source defect repair, A2):
     * the AIDL compiler numbers methods by declaration order, so every
     * appended method stays after all earlier methods. [wire2LegacyMethods]
     * lists the exact legacy order and the `wireN*` lists the additions; the
     * contract tests assert both against the .aidl source so a future
     * insertion can never silently shift a legacy transaction number again.
     */
    const val VERSION = 4

    /**
     * Exact wire-2 method order (do not reorder; this is the binary contract
     * a same-versionCode old service still answers on).
     */
    val wire2LegacyMethods: List<String> = listOf(
        "protocolVersion", "ping", "describe",
        "registerGrant", "revokeGrant", "revokeAllGrants",
        "fileList", "fileRead", "fileWrite", "fileMove", "fileDelete",
        "processQuery", "serviceQuery", "packageQuery", "networkDiagnostics",
        "managePackage", "packetCapture",
        "cancel", "stopOwnedService",
    )

    /** Wire-3 methods appended after [wire2LegacyMethods]. */
    val wire3AppendedMethods: List<String> = listOf(
        "installPackage", "uninstallPackage", "stageApk",
    )

    // Settings transactions appended after the app-state/cache block. Wire 3
    // has never shipped publicly, so these ride the same protocol revision
    // and VERSION stays 3; the first nineteen legacy positions stay untouched.
    val wire6AppendedMethods: List<String> = listOf(
        "readSettings", "writeSettings",
    )

    /**
     * Wire-4 structured-UI transactions. Released build 108 carried VERSION=3,
     * so these are a real append-only revision: `uiStatus` first (readiness)
     * then observe/act/screenshot/cancel. Never insert before this block.
     */
    val wire7AppendedMethods: List<String> = listOf(
        "uiStatus", "uiObserve", "uiAct", "uiScreenshot", "uiCancel",
    )

    /**
     * App-state methods appended after [wire3AppendedMethods]. Wire 3 has
     * never shipped publicly, so these ride the same protocol revision; the
     * legacy wire-2 positions above stay untouched.
     */
    val wire4AppendedMethods: List<String> = listOf(
        "setPackageEnabled", "removePackageForUser", "restorePackage",
        "releaseStagedApk",
    )

    /**
     * Permission/AppOps methods appended after [wire4AppendedMethods] on the
     * same unshipped protocol revision. Appending keeps every earlier
     * transaction number stable; VERSION stays 3 because no wire-3 APK ever
     * shipped.
     */
    val wire5AppendedMethods: List<String> = listOf(
        "queryPermissions", "managePermissions", "queryAppOps", "manageAppOps",
    )

    /** Every method appended after the legacy wire-2 block, in order. */
    val appendedMethods: List<String> =
        wire3AppendedMethods + wire4AppendedMethods + wire5AppendedMethods +
            wire6AppendedMethods + wire7AppendedMethods

    const val MAX_LIST = 500
    const val MAX_READ_BYTES = 1024 * 1024
    const val MAX_WRITE_BYTES = 8 * 1024 * 1024
    const val MAX_NAME = 255
    const val MAX_RELATIVE_PATH = 512
    const val MAX_TEXT = 512

    const val MODE_ADB = "adb"
    const val MODE_ROOT = "root"

    // Common claim keys.
    const val KEY_TASK_ID = "taskId"
    const val KEY_RUN_ID = "runId"
    const val KEY_EPOCH = "epoch"
    const val KEY_GRANT_ID = "grantId"
    const val KEY_REQUEST_ID = "requestId"
    const val KEY_CALL_ID = "callId"
    const val KEY_OPERATION = "operation"
    const val KEY_SCOPE_ID = "scopeId"
    const val KEY_RELATIVE_PATH = "relativePath"
    const val KEY_FROM_PATH = "fromPath"
    const val KEY_TO_PATH = "toPath"
    const val KEY_OVERWRITE = "overwrite"
    const val KEY_RECURSIVE = "recursive"
    const val KEY_OFFSET = "offset"
    const val KEY_MAX_BYTES = "maxBytes"
    const val KEY_MAX_ENTRIES = "maxEntries"
    const val KEY_FILTER = "filter"
    const val KEY_PACKAGE_NAME = "packageName"
    const val KEY_INCLUDE_SYSTEM = "includeSystem"
    const val KEY_INCLUDE_UNINSTALLED = "includeUninstalled"
    const val KEY_USER_ID = "userId"
    const val KEY_PACKAGE_STATE = "packageState"
    const val KEY_REQUESTED_STATE = "requestedState"
    const val KEY_STATE_AFTER = "stateAfter"
    const val KEY_PACKAGE_TARGETS = "packageTargets"
    const val KEY_EXPECTED_PID = "expectedPid"
    const val KEY_APK_PATH = "apkPath"
    const val KEY_SOURCE_PATH = "sourcePath"
    const val KEY_STAGED_PATH = "stagedPath"
    const val KEY_SIZE_BYTES = "sizeBytes"
    const val KEY_SHA256 = "sha256"
    const val KEY_EXPECTED_SHA256 = "expectedSha256"
    const val KEY_EXPECTED_SIZE = "expectedSizeBytes"
    const val KEY_EXPECTED_PACKAGE = "expectedPackageName"
    const val KEY_SUCCEEDED = "succeeded"
    const val KEY_PRESENT_AFTER = "presentAfter"
    const val KEY_DETAIL_CODE = "detailCode"
    const val KEY_FAILURE_DETAIL = "failureDetail"

    // Permission/AppOps request+reply keys (closed set; values bounded).
    const val KEY_PERMISSION_NAME = "permissionName"
    const val KEY_PERMISSION_ACTION = "permissionAction"
    const val KEY_PERMISSIONS = "permissions"
    const val KEY_APPOP_OPERATION = "appOpOperation"
    const val KEY_APPOP_MODE = "appOpMode"
    const val KEY_APPOPS = "appOps"
    const val KEY_GRANTED = "granted"
    const val KEY_GRANTED_BEFORE = "grantedBefore"
    const val KEY_PROTECTION_LEVEL = "protectionLevel"
    const val KEY_OVERRIDE_MODE = "overrideMode"
    const val KEY_UID_MODE = "uidMode"
    const val KEY_DEFAULT_MODE = "defaultMode"
    const val KEY_EFFECTIVE_MODE = "effectiveMode"
    const val KEY_OVERRIDE_BEFORE = "overrideBefore"
    const val KEY_UID_BEFORE = "uidBefore"
    const val KEY_DEFAULT_BEFORE = "defaultBefore"
    const val KEY_EFFECTIVE_BEFORE = "effectiveBefore"
    const val KEY_REQUESTED_MODE = "requestedMode"
    const val KEY_OP_NAME = "opName"
    // AppOps UID write scope (N02): request scope token, service-resolved
    // UID, observed UID-level row after the set, and the grant allowance
    // that binds the scope into the canonical grant registration.
    const val KEY_APPOP_SCOPE = "appOpScope"
    const val KEY_RESOLVED_UID = "resolvedUid"
    const val KEY_UID_AFTER = "uidAfter"
    const val KEY_APPOPS_UID_SCOPE = "appOpsUidScope"

    // ----------------------------------------------------- typed UI (wire 4)
    const val KEY_UI_TARGETS = "uiTargets"
    const val KEY_UI_SCREEN = "uiScreenAllowed"
    const val KEY_UI_SCREENSHOT = "uiScreenshotAllowed"
    const val KEY_UI_MODE = "uiMode"
    const val KEY_UI_OBSERVATION_ID = "uiObservationId"
    const val KEY_UI_NODE_REF = "uiNodeRef"
    const val KEY_UI_ACTION = "uiAction"
    const val KEY_UI_DIRECTION = "uiDirection"
    /**
     * One-shot SET_TEXT payload. The historical key name is retained for the
     * already-defined v4 Bundle; the separate intent flag below decides
     * whether the bytes may enter a protected field. Never logged.
     */
    const val KEY_UI_SENSITIVE_TEXT = "uiSensitiveText"
    /**
     * Appended v4 Bundle extra: true only when the caller explicitly used the
     * existing `device.act` `sensitiveText` parameter. Absent/false keeps
     * ordinary-text behaviour, so an older in-flight Bundle stays valid and
     * no transaction position changes.
     */
    const val KEY_UI_SENSITIVE_TEXT_INTENT = "uiSensitiveTextIntent"
    const val KEY_UI_MAX_NODES = "uiMaxNodes"
    const val KEY_UI_MAX_DEPTH = "uiMaxDepth"
    const val KEY_UI_MAX_DIMENSION = "uiMaxDimension"
    const val KEY_UI_QUALITY = "uiQuality"
    const val KEY_UI_INCLUDE_INVISIBLE = "uiIncludeInvisible"
    const val KEY_UI_TEXT_BUDGET = "uiTextBudget"
    const val KEY_UI_OBSERVATION = "uiObservation"
    const val KEY_UI_NODES = "uiNodes"
    const val KEY_UI_PACKAGE = "uiPackage"
    const val KEY_UI_WINDOW_ID = "uiWindowId"
    const val KEY_UI_WINDOW_TYPE = "uiWindowType"
    const val KEY_UI_WINDOW_TITLE = "uiWindowTitle"
    const val KEY_UI_DISPLAY_ID = "uiDisplayId"
    const val KEY_UI_ROOT_CLASS = "uiRootClass"
    const val KEY_UI_ROTATION = "uiRotation"
    const val KEY_UI_CAPTURED_AT = "uiCapturedAt"
    const val KEY_UI_EXPIRES_AT = "uiExpiresAt"
    const val KEY_UI_GENERATION = "uiGeneration"
    const val KEY_UI_USER_REVISION = "uiUserRevision"
    const val KEY_UI_SCANNED = "uiScanned"
    const val KEY_UI_MAX_DEPTH_REACHED = "uiMaxDepthReached"
    const val KEY_UI_SCAN_LIMITED = "uiScanLimited"
    const val KEY_UI_TIME_LIMITED = "uiTimeLimited"
    const val KEY_UI_SELECTION_LIMITED = "uiSelectionLimited"
    const val KEY_UI_TEXT_LIMITED = "uiTextLimited"
    const val KEY_UI_SENSITIVE_WINDOW = "uiSensitiveWindow"
    const val KEY_UI_SENSITIVE_FIELD = "uiSensitiveField"
    const val KEY_UI_NAVIGATION_ONLY = "uiNavigationOnly"
    const val KEY_UI_BACKEND = "uiBackend"
    const val KEY_UI_PROVENANCE = "uiProvenance"
    const val KEY_UI_DISPATCH = "uiDispatch"
    const val KEY_UI_METHOD = "uiMethod"
    const val KEY_UI_SCREEN_CHANGED = "uiScreenChanged"
    const val KEY_UI_DETAIL_CODE = "uiDetailCode"
    const val KEY_UI_DETAIL = "uiDetail"
    const val KEY_UI_SCREENSHOT_ID = "uiScreenshotId"
    const val KEY_UI_MIME = "uiMime"
    const val KEY_UI_WIDTH = "uiWidth"
    const val KEY_UI_HEIGHT = "uiHeight"
    const val KEY_UI_ORIGINAL_WIDTH = "uiOriginalWidth"
    const val KEY_UI_ORIGINAL_HEIGHT = "uiOriginalHeight"
    const val KEY_UI_BYTES_TOTAL = "uiBytesTotal"
    const val KEY_UI_SCREEN_SUPPORT = "uiScreenSupport"
    const val KEY_UI_READY = "uiReady"
    const val KEY_UI_LIVE = "uiLive"
    const val KEY_UI_REASON = "uiReason"
    const val KEY_UI_USER_INTERACTION = "uiUserInteraction"
    const val KEY_UI_TTL = "uiTtl"
    const val KEY_UI_MAX_NODE_LIMIT = "uiMaxNodeLimit"
    const val KEY_UI_CHUNK = "uiChunk"
    const val KEY_UI_DONE = "uiDone"
    const val KEY_UI_BYTES_READ = "uiBytesRead"
    const val KEY_UI_RANGE = "uiRange"
    const val KEY_UI_RANGE_MIN = "uiRangeMin"
    const val KEY_UI_RANGE_MAX = "uiRangeMax"
    const val KEY_UI_RANGE_CURRENT = "uiRangeCurrent"
    const val KEY_UI_ACTIONS = "uiActions"
    const val KEY_UI_PATH = "uiPath"
    const val KEY_UI_LEFT = "uiLeft"
    const val KEY_UI_TOP = "uiTop"
    const val KEY_UI_RIGHT = "uiRight"
    const val KEY_UI_BOTTOM = "uiBottom"
    const val KEY_UI_DEPTH = "uiDepth"
    const val KEY_UI_CLASS = "uiClass"
    const val KEY_UI_VIEW_ID = "uiViewId"
    const val KEY_UI_TEXT = "uiText"
    const val KEY_UI_DESCRIPTION = "uiDescription"
    const val KEY_UI_HINT = "uiHint"
    const val KEY_UI_VISIBLE = "uiVisible"
    const val KEY_UI_ENABLED = "uiEnabled"
    const val KEY_UI_CLICKABLE = "uiClickable"
    const val KEY_UI_EDITABLE = "uiEditable"
    const val KEY_UI_SCROLLABLE = "uiScrollable"
    const val KEY_UI_FOCUSABLE = "uiFocusable"
    const val KEY_UI_FOCUSED = "uiFocused"
    const val KEY_UI_SELECTED = "uiSelected"
    const val KEY_UI_CHECKABLE = "uiCheckable"
    const val KEY_UI_CHECKED = "uiChecked"
    const val KEY_UI_PASSWORD = "uiPassword"
    const val KEY_UI_REDACTED = "uiRedacted"
    const val KEY_UI_INSIDE_SCROLL = "uiInsideScrollable"
    const val MAX_UI_NODES = 400
    const val MAX_UI_TEXT = 2_000
    const val MAX_UI_SET_TEXT = 2_000
    const val MAX_UI_ACTIONS = 16
    const val MAX_UI_PATH = 64
    val UI_DIRECTIONS: Set<String> = setOf("forward", "backward", "up", "down", "left", "right")
    const val MAX_UI_SCREENSHOT_BYTES = 6_000_000
    const val MAX_UI_SCREENSHOT_CHUNK = 64 * 1024

    // Pinned packet-capture request/reply keys (no command or arbitrary path).
    const val KEY_CAPTURE_MODE = "captureMode"
    const val KEY_CAPTURE_ID = "captureId"
    const val KEY_HELPER_ID = "helperId"
    const val KEY_INTERFACE_NAME = "interfaceName"
    const val KEY_SNAPLEN = "snaplen"
    const val KEY_MAX_MILLIS = "maxMillis"
    const val KEY_HELPER_PATH = "helperPath"
    const val KEY_CAPTURE_CHUNK = "captureChunk"
    const val KEY_CAPTURE_DONE = "captureDone"
    const val KEY_CAPTURE_END = "captureEnd"
    const val MAX_CAPTURE_CHUNK = 256 * 1024

    // Grant keys.
    const val KEY_SCOPE_IDS = "scopeIds"
    const val KEY_SCOPE_PATHS = "scopePaths"
    const val KEY_SCOPE_WRITABLE = "scopeWritable"
    const val KEY_OPERATIONS = "operations"
    const val KEY_PACKAGE_MANAGEMENT = "packageManagement"
    const val KEY_EXPIRES_AT = "expiresAt"

    // Reply keys.
    const val KEY_OK = "ok"
    const val KEY_CODE = "code"
    const val KEY_MESSAGE = "message"
    const val KEY_ENTRIES = "entries"
    const val KEY_SCOPES = "scopes"
    const val KEY_BYTES_READ = "bytesRead"
    const val KEY_DATA = "data"
    const val KEY_TRUNCATED = "truncated"
    const val KEY_BYTES_WRITTEN = "bytesWritten"
    const val KEY_ATOMIC = "atomic"
    const val KEY_DELETED = "deleted"
    const val KEY_PROCESSES = "processes"
    const val KEY_SERVICES = "services"
    const val KEY_PACKAGES = "packages"
    const val KEY_INTERFACES = "interfaces"
    const val KEY_ROUTES = "routes"
    const val KEY_TRANSPORTS = "transports"
    const val KEY_STILL_RUNNING = "stillRunning"
    const val KEY_PACKAGE_RESULT = "packageResult"

    // describe() keys.
    const val KEY_SERVER_UID = "serverUid"
    const val KEY_SERVER_PID = "serverPid"
    const val KEY_SERVER_MODE = "serverMode"
    const val KEY_PROTOCOL = "protocol"
    const val KEY_PACKAGE = "package"
    const val KEY_APP_VERSION = "appVersion"
    const val KEY_SIGNING_SHA256 = "signingSha256"
    const val KEY_GENERATION = "generation"
    const val KEY_CAPABILITIES = "capabilities"

    // Provider publication keys.
    const val KEY_BINDER = "binder"
    const val KEY_CLIENT = "client"
    const val KEY_TOKEN = "token"

    fun claimBundle(claim: OperationClaim, operation: SystemOperation): Bundle = Bundle().apply {
        putString(KEY_TASK_ID, claim.taskId)
        putString(KEY_RUN_ID, claim.runId)
        putLong(KEY_EPOCH, claim.epoch)
        putString(KEY_GRANT_ID, claim.grantId)
        putString(KEY_REQUEST_ID, claim.requestId)
        claim.callId?.let { putString(KEY_CALL_ID, it) }
        putString(KEY_OPERATION, operation.name)
    }

    fun grantBundle(request: GrantRequest): Bundle = Bundle().apply {
        putString(KEY_GRANT_ID, request.grantId)
        putString(KEY_TASK_ID, request.taskId)
        putString(KEY_RUN_ID, request.runId)
        putLong(KEY_EPOCH, request.epoch)
        putLong(KEY_EXPIRES_AT, request.expiresAtMillis)
        putStringArray(KEY_SCOPE_IDS, request.scopes.map { it.scopeId }.toTypedArray())
        putStringArray(KEY_SCOPE_PATHS, request.scopes.map { it.path }.toTypedArray())
        putBooleanArray(KEY_SCOPE_WRITABLE, request.scopes.map { it.writable }.toBooleanArray())
        putStringArray(KEY_OPERATIONS, request.operations.map { it.name }.toTypedArray())
        putBoolean(KEY_PACKAGE_MANAGEMENT, request.packageManagementAllowed)
        if (request.appOpsUidScopeAllowed) {
            putBoolean(KEY_APPOPS_UID_SCOPE, true)
        }
        if (request.packageTargets.isNotEmpty()) {
            putStringArray(
                KEY_PACKAGE_TARGETS,
                request.packageTargets.take(com.floe.android.rootsystem.GrantRequest.MAX_PACKAGE_TARGETS)
                    .toTypedArray(),
            )
        }
        if (request.uiTargets.isNotEmpty()) {
            putStringArray(
                KEY_UI_TARGETS,
                request.uiTargets.take(com.floe.android.rootsystem.GrantRequest.MAX_PACKAGE_TARGETS)
                    .toTypedArray(),
            )
        }
        if (request.uiScreenAllowed) putBoolean(KEY_UI_SCREEN, true)
        if (request.uiScreenshotAllowed) putBoolean(KEY_UI_SCREENSHOT, true)
    }

    fun parseGrant(bundle: Bundle?): GrantRequest? {
        if (bundle == null) return null
        val ids = bundle.getStringArray(KEY_SCOPE_IDS) ?: return null
        val paths = bundle.getStringArray(KEY_SCOPE_PATHS) ?: return null
        val writable = bundle.getBooleanArray(KEY_SCOPE_WRITABLE) ?: return null
        val ops = bundle.getStringArray(KEY_OPERATIONS) ?: return null
        if (ids.size != paths.size || ids.size != writable.size) return null
        if (ids.size > 8 || ops.size !in 1..SystemOperation.entries.size) return null
        val operations = LinkedHashSet<SystemOperation>()
        for (name in ops) {
            operations.add(SystemOperation.entries.firstOrNull { it.name == name } ?: return null)
        }
        if (ids.isEmpty() && operations.any { it !in SystemOperation.UI_OPERATIONS }) return null
        return GrantRequest(
            grantId = bundle.getString(KEY_GRANT_ID) ?: return null,
            taskId = bundle.getString(KEY_TASK_ID) ?: return null,
            runId = bundle.getString(KEY_RUN_ID) ?: return null,
            epoch = bundle.getLong(KEY_EPOCH),
            expiresAtMillis = bundle.getLong(KEY_EXPIRES_AT),
            scopes = ids.indices.map { ScopeRoot(ids[it], paths[it], writable[it]) },
            operations = operations,
            packageManagementAllowed = bundle.getBoolean(KEY_PACKAGE_MANAGEMENT),
            appOpsUidScopeAllowed = bundle.getBoolean(KEY_APPOPS_UID_SCOPE, false),
            packageTargets = (bundle.getStringArray(KEY_PACKAGE_TARGETS) ?: emptyArray())
                .take(com.floe.android.rootsystem.GrantRequest.MAX_PACKAGE_TARGETS)
                .toSet(),
            uiTargets = (bundle.getStringArray(KEY_UI_TARGETS) ?: emptyArray())
                .take(com.floe.android.rootsystem.GrantRequest.MAX_PACKAGE_TARGETS)
                .toSet(),
            uiScreenAllowed = bundle.getBoolean(KEY_UI_SCREEN, false),
            uiScreenshotAllowed = bundle.getBoolean(KEY_UI_SCREENSHOT, false),
        )
    }

    fun parseClaim(bundle: Bundle?): OperationClaim? {
        if (bundle == null) return null
        val task = bundle.getString(KEY_TASK_ID) ?: return null
        val run = bundle.getString(KEY_RUN_ID) ?: return null
        val grant = bundle.getString(KEY_GRANT_ID) ?: return null
        val request = bundle.getString(KEY_REQUEST_ID) ?: return null
        val claim = OperationClaim(
            taskId = task,
            runId = run,
            epoch = bundle.getLong(KEY_EPOCH),
            grantId = grant,
            requestId = request,
            callId = bundle.getString(KEY_CALL_ID),
        )
        return if (claim.isWellFormed()) claim else null
    }

    fun parseOperation(bundle: Bundle?): SystemOperation? {
        val name = bundle?.getString(KEY_OPERATION) ?: return null
        return SystemOperation.entries.firstOrNull { it.name == name }
    }

    fun ok(): Bundle = Bundle().apply { putBoolean(KEY_OK, true) }

    fun failure(code: String, message: String? = null): Bundle = Bundle().apply {
        putBoolean(KEY_OK, false)
        putString(KEY_CODE, code)
        if (message != null) putString(KEY_MESSAGE, message.take(MAX_TEXT))
    }

    fun isOk(bundle: Bundle?): Boolean = bundle?.getBoolean(KEY_OK, false) == true

    fun code(bundle: Bundle?): String? = bundle?.getString(KEY_CODE)

    fun entries(bundle: Bundle?): List<FileEntry>? {
        val array = bundleArray(bundle, KEY_ENTRIES) ?: return null
        if (array.size > MAX_LIST) return null
        return array.mapNotNull { entry ->
            if (entry == null) return@mapNotNull null
            val name = entry.getString("name") ?: return@mapNotNull null
            val path = entry.getString("relativePath") ?: return@mapNotNull null
            FileEntry(
                name = name.take(MAX_NAME),
                relativePath = path.take(MAX_RELATIVE_PATH),
                directory = entry.getBoolean("directory"),
                sizeBytes = entry.getLong("size"),
                modifiedAtMillis = entry.getLong("modified"),
            )
        }
    }

    fun entryBundles(entries: List<FileEntry>): Array<Bundle> = entries.map { entry ->
        Bundle().apply {
            putString("name", entry.name)
            putString("relativePath", entry.relativePath)
            putBoolean("directory", entry.directory)
            putLong("size", entry.sizeBytes)
            putLong("modified", entry.modifiedAtMillis)
        }
    }.toTypedArray()

    fun processes(bundle: Bundle?): List<ProcessRecord>? {
        val array = bundleArray(bundle, KEY_PROCESSES) ?: return null
        if (array.size > MAX_LIST) return null
        return array.mapNotNull { item ->
            item?.let {
                ProcessRecord(
                    pid = it.getInt("pid"),
                    uid = it.getInt("uid"),
                    name = it.getString("name")?.take(MAX_NAME) ?: return@mapNotNull null,
                )
            }
        }
    }

    fun services(bundle: Bundle?): List<ServiceRecord>? {
        val array = bundleArray(bundle, KEY_SERVICES) ?: return null
        if (array.size > MAX_LIST) return null
        return array.mapNotNull { item ->
            item?.let {
                ServiceRecord(
                    processName = it.getString("process")?.take(MAX_NAME) ?: return@mapNotNull null,
                    className = it.getString("className")?.take(MAX_TEXT) ?: return@mapNotNull null,
                    pid = it.getInt("pid"),
                    foreground = it.getBoolean("foreground"),
                )
            }
        }
    }

    fun packages(bundle: Bundle?): PackageQuery? {
        if (bundle == null) return null
        val array = bundleArray(bundle, KEY_PACKAGES) ?: return null
        if (array.size > MAX_LIST) return null
        val list = array.mapNotNull { item ->
            item?.let {
                PackageRecord(
                    packageName = it.getString("packageName")?.take(MAX_NAME) ?: return@mapNotNull null,
                    uid = it.getInt("uid"),
                    versionCode = it.getLong("versionCode"),
                    system = it.getBoolean("system"),
                    enabled = it.getBoolean("enabled"),
                    running = it.getBoolean("running"),
                )
            }
        }
        return PackageQuery(list, bundle.getBoolean(KEY_TRUNCATED))
    }

    fun network(bundle: Bundle?): NetworkDiagnostics? {
        if (bundle == null) return null
        val interfaceBundles = bundleArray(bundle, KEY_INTERFACES) ?: return null
        val routeBundles = bundleArray(bundle, KEY_ROUTES) ?: return null
        if (interfaceBundles.size > MAX_LIST || routeBundles.size > MAX_LIST) return null
        val interfaces = interfaceBundles.mapNotNull { item ->
            item?.let {
                InterfaceInfo(
                    name = it.getString("name")?.take(MAX_NAME) ?: return@mapNotNull null,
                    up = it.getBoolean("up"),
                    addresses = (it.getStringArray("addresses") ?: emptyArray())
                        .take(32).map { address -> address.take(128) },
                )
            }
        }
        val routes = routeBundles.mapNotNull { item ->
            item?.let {
                RouteInfo(
                    interfaceName = it.getString("interfaceName")?.take(MAX_NAME)
                        ?: return@mapNotNull null,
                    destination = it.getString("destination")?.take(MAX_TEXT)
                        ?: return@mapNotNull null,
                    gateway = it.getString("gateway")?.take(MAX_TEXT),
                    defaultRoute = it.getBoolean("defaultRoute"),
                )
            }
        }
        val transports = (bundle.getStringArray(KEY_TRANSPORTS) ?: emptyArray())
            .take(8).map { it.take(32) }
        return NetworkDiagnostics(interfaces, routes, transports)
    }

    @Suppress("DEPRECATION")
    private fun bundleArray(bundle: Bundle?, key: String): Array<Bundle>? {
        val raw = bundle?.getParcelableArray(key) ?: return null
        if (raw.size > MAX_LIST) return null
        val out = ArrayList<Bundle>(raw.size)
        for (item in raw) out.add(item as? Bundle ?: return null)
        return out.toTypedArray()
    }

    fun packageResult(bundle: Bundle?): PackageManagementReceipt? {
        val item = bundle?.getBundle(KEY_PACKAGE_RESULT) ?: return null
        return PackageManagementReceipt(
            packageName = item.getString("packageName")?.take(MAX_NAME) ?: return null,
            userId = item.getInt("userId"),
            operation = item.getString("operation")?.take(32) ?: return null,
            stillRunning = item.getBoolean(KEY_STILL_RUNNING),
        )
    }

    fun packageLifecycleResult(bundle: Bundle?): com.floe.android.rootsystem.PackageLifecycleReceipt? {
        val item = bundle?.getBundle(KEY_PACKAGE_RESULT) ?: return null
        return com.floe.android.rootsystem.PackageLifecycleReceipt(
            packageName = item.getString(KEY_PACKAGE_NAME)?.take(MAX_NAME) ?: return null,
            userId = item.getInt(KEY_USER_ID),
            operation = item.getString("operation")?.take(32) ?: return null,
            succeeded = item.getBoolean(KEY_SUCCEEDED),
            presentAfter = item.getBoolean(KEY_PRESENT_AFTER),
            versionCode = item.getLong("versionCode"),
            detailCode = item.getString(KEY_DETAIL_CODE)?.take(48) ?: return null,
            failureDetail = item.getString(KEY_FAILURE_DETAIL)?.take(96),
        )
    }

    /** Reply codec for the typed shared-storage -> staging-area APK copy. */
    fun stagedCopyResult(bundle: Bundle?): com.floe.android.rootsystem.StagedCopyReceipt? {
        val item = bundle?.getBundle(KEY_PACKAGE_RESULT) ?: return null
        val stagedPath = item.getString(KEY_STAGED_PATH) ?: return null
        val sha = item.getString(KEY_SHA256) ?: return null
        if (sha.length != 64) return null
        return com.floe.android.rootsystem.StagedCopyReceipt(
            stagedPath = stagedPath.take(MAX_RELATIVE_PATH + 384),
            sizeBytes = item.getLong(KEY_SIZE_BYTES),
            sha256 = sha,
            packageName = item.getString(KEY_PACKAGE_NAME)?.take(MAX_NAME),
        )
    }

    /** Reply codec for the typed enable/disable/disable-user state receipt. */
    fun packageStateResult(bundle: Bundle?): com.floe.android.rootsystem.PackageStateReceipt? {
        val item = bundle?.getBundle(KEY_PACKAGE_RESULT) ?: return null
        return com.floe.android.rootsystem.PackageStateReceipt(
            packageName = item.getString(KEY_PACKAGE_NAME)?.take(MAX_NAME) ?: return null,
            userId = item.getInt(KEY_USER_ID),
            operation = item.getString("operation")?.take(32) ?: return null,
            requestedState = item.getString(KEY_REQUESTED_STATE)?.take(32) ?: return null,
            stateAfter = item.getString(KEY_STATE_AFTER)?.take(32) ?: return null,
            succeeded = item.getBoolean(KEY_SUCCEEDED),
            detailCode = item.getString(KEY_DETAIL_CODE)?.take(48) ?: return null,
            failureDetail = item.getString(KEY_FAILURE_DETAIL)?.take(96),
        )
    }

    // -------------------------------------------------- permissions/appops

    private fun nullableString(item: Bundle, key: String, max: Int): String? =
        if (item.containsKey(key)) item.getString(key)?.take(max) else null

    /** Reply rows for system.permissions.query (bounded list). */
    fun permissionStates(bundle: Bundle?): List<com.floe.android.rootsystem.PermissionState>? {
        val array = bundleArray(bundle, KEY_PERMISSIONS) ?: return null
        if (array.size > MAX_LIST) return null
        return array.mapNotNull { item ->
            item?.let {
                com.floe.android.rootsystem.PermissionState(
                    name = it.getString(KEY_PERMISSION_NAME)?.take(MAX_NAME)
                        ?: return@mapNotNull null,
                    protectionLevel = it.getString(KEY_PROTECTION_LEVEL)?.take(32)
                        ?: return@mapNotNull null,
                    granted = it.getBoolean(KEY_GRANTED),
                )
            }
        }
    }

    fun permissionStateBundles(
        states: List<com.floe.android.rootsystem.PermissionState>,
    ): Array<Bundle> = states.map { state ->
        Bundle().apply {
            putString(KEY_PERMISSION_NAME, state.name.take(MAX_NAME))
            putString(KEY_PROTECTION_LEVEL, state.protectionLevel.take(32))
            putBoolean(KEY_GRANTED, state.granted)
        }
    }.toTypedArray()

    /** Reply codec for the typed pm grant/revoke receipt. */
    fun permissionSetResult(bundle: Bundle?): com.floe.android.rootsystem.PermissionSetReceipt? {
        val item = bundle?.getBundle(KEY_PACKAGE_RESULT) ?: return null
        return com.floe.android.rootsystem.PermissionSetReceipt(
            packageName = item.getString(KEY_PACKAGE_NAME)?.take(MAX_NAME) ?: return null,
            userId = item.getInt(KEY_USER_ID),
            permission = item.getString(KEY_PERMISSION_NAME)?.take(MAX_NAME) ?: return null,
            action = item.getString(KEY_PERMISSION_ACTION)?.take(16) ?: return null,
            grantedBefore = item.getBoolean(KEY_GRANTED_BEFORE),
            grantedAfter = item.getBoolean(KEY_GRANTED),
            succeeded = item.getBoolean(KEY_SUCCEEDED),
            detailCode = item.getString(KEY_DETAIL_CODE)?.take(48) ?: return null,
            failureDetail = item.getString(KEY_FAILURE_DETAIL)?.take(96),
        )
    }

    /** Reply rows for system.appOps.query (bounded list). */
    fun appOpsStates(bundle: Bundle?): List<com.floe.android.rootsystem.AppOpsModeState>? {
        val array = bundleArray(bundle, KEY_APPOPS) ?: return null
        if (array.size > MAX_LIST) return null
        return array.mapNotNull { item ->
            item?.let {
                com.floe.android.rootsystem.AppOpsModeState(
                    operation = it.getString(KEY_APPOP_OPERATION)?.take(32)
                        ?: return@mapNotNull null,
                    opName = it.getString(KEY_OP_NAME)?.take(64) ?: return@mapNotNull null,
                    overrideMode = nullableString(it, KEY_OVERRIDE_MODE, 16),
                    uidMode = nullableString(it, KEY_UID_MODE, 16),
                    defaultMode = nullableString(it, KEY_DEFAULT_MODE, 16),
                    effective = it.getString(KEY_EFFECTIVE_MODE)?.take(16)
                        ?: return@mapNotNull null,
                )
            }
        }
    }

    fun appOpsStateBundles(
        states: List<com.floe.android.rootsystem.AppOpsModeState>,
    ): Array<Bundle> = states.map { state ->
        Bundle().apply {
            putString(KEY_APPOP_OPERATION, state.operation.take(32))
            putString(KEY_OP_NAME, state.opName.take(64))
            state.overrideMode?.let { putString(KEY_OVERRIDE_MODE, it.take(16)) }
            state.uidMode?.let { putString(KEY_UID_MODE, it.take(16)) }
            state.defaultMode?.let { putString(KEY_DEFAULT_MODE, it.take(16)) }
            putString(KEY_EFFECTIVE_MODE, state.effective.take(16))
        }
    }.toTypedArray()

    // ------------------------------------------------------------ typed UI

    private fun uiNodeBundle(node: com.floe.android.rootsystem.UiNode): Bundle = Bundle().apply {
        putString("ref", node.ref.take(32))
        node.parentRef?.let { putString("parentRef", it.take(32)) }
        putInt(KEY_UI_DEPTH, node.depth)
        putString(KEY_UI_CLASS, node.className.take(200))
        node.packageName?.let { putString(KEY_UI_PACKAGE, it.take(MAX_NAME)) }
        node.viewId?.let { putString(KEY_UI_VIEW_ID, it.take(255)) }
        node.text?.let { putString(KEY_UI_TEXT, it.take(MAX_UI_TEXT)) }
        node.contentDescription?.let { putString(KEY_UI_DESCRIPTION, it.take(MAX_UI_TEXT)) }
        node.hintText?.let { putString(KEY_UI_HINT, it.take(MAX_UI_TEXT)) }
        putInt(KEY_UI_LEFT, node.bounds.left)
        putInt(KEY_UI_TOP, node.bounds.top)
        putInt(KEY_UI_RIGHT, node.bounds.right)
        putInt(KEY_UI_BOTTOM, node.bounds.bottom)
        putBoolean(KEY_UI_VISIBLE, node.visible)
        putBoolean(KEY_UI_ENABLED, node.enabled)
        putBoolean(KEY_UI_CLICKABLE, node.clickable)
        putBoolean(KEY_UI_EDITABLE, node.editable)
        putBoolean(KEY_UI_SCROLLABLE, node.scrollable)
        putBoolean(KEY_UI_FOCUSABLE, node.focusable)
        putBoolean(KEY_UI_FOCUSED, node.focused)
        putBoolean(KEY_UI_SELECTED, node.selected)
        putBoolean(KEY_UI_CHECKABLE, node.checkable)
        putBoolean(KEY_UI_CHECKED, node.checked)
        putBoolean(KEY_UI_PASSWORD, node.password)
        putBoolean(KEY_UI_REDACTED, node.redacted)
        putBoolean(KEY_UI_INSIDE_SCROLL, node.insideScrollable)
        putStringArray(KEY_UI_ACTIONS, node.actions.take(MAX_UI_ACTIONS).toTypedArray())
        node.range?.let { range ->
            putBundle(KEY_UI_RANGE, Bundle().apply {
                putFloat(KEY_UI_RANGE_MIN, range.min)
                putFloat(KEY_UI_RANGE_MAX, range.max)
                putFloat(KEY_UI_RANGE_CURRENT, range.current)
            })
        }
        if (node.path.isNotEmpty()) {
            putIntArray(KEY_UI_PATH, node.path.take(MAX_UI_PATH).toIntArray())
        }
    }

    private fun parseUiNode(item: Bundle?): com.floe.android.rootsystem.UiNode? {
        if (item == null) return null
        val ref = item.getString("ref")?.take(32) ?: return null
        val range = item.getBundle(KEY_UI_RANGE)?.let {
            com.floe.android.rootsystem.UiRangeInfo(
                it.getFloat(KEY_UI_RANGE_MIN),
                it.getFloat(KEY_UI_RANGE_MAX),
                it.getFloat(KEY_UI_RANGE_CURRENT),
            )
        }
        return com.floe.android.rootsystem.UiNode(
            ref = ref,
            parentRef = item.getString("parentRef")?.take(32),
            depth = item.getInt(KEY_UI_DEPTH).coerceIn(0, 64),
            className = item.getString(KEY_UI_CLASS)?.take(200).orEmpty(),
            packageName = item.getString(KEY_UI_PACKAGE)?.take(MAX_NAME),
            viewId = item.getString(KEY_UI_VIEW_ID)?.take(255),
            text = item.getString(KEY_UI_TEXT)?.take(MAX_UI_TEXT),
            contentDescription = item.getString(KEY_UI_DESCRIPTION)?.take(MAX_UI_TEXT),
            hintText = item.getString(KEY_UI_HINT)?.take(MAX_UI_TEXT),
            bounds = com.floe.android.rootsystem.UiBounds(
                left = item.getInt(KEY_UI_LEFT),
                top = item.getInt(KEY_UI_TOP),
                right = item.getInt(KEY_UI_RIGHT),
                bottom = item.getInt(KEY_UI_BOTTOM),
            ),
            visible = item.getBoolean(KEY_UI_VISIBLE),
            enabled = item.getBoolean(KEY_UI_ENABLED),
            clickable = item.getBoolean(KEY_UI_CLICKABLE),
            editable = item.getBoolean(KEY_UI_EDITABLE),
            scrollable = item.getBoolean(KEY_UI_SCROLLABLE),
            focusable = item.getBoolean(KEY_UI_FOCUSABLE),
            focused = item.getBoolean(KEY_UI_FOCUSED),
            selected = item.getBoolean(KEY_UI_SELECTED),
            checkable = item.getBoolean(KEY_UI_CHECKABLE),
            checked = item.getBoolean(KEY_UI_CHECKED),
            password = item.getBoolean(KEY_UI_PASSWORD),
            redacted = item.getBoolean(KEY_UI_REDACTED),
            insideScrollable = item.getBoolean(KEY_UI_INSIDE_SCROLL),
            actions = (item.getStringArray(KEY_UI_ACTIONS) ?: emptyArray())
                .take(MAX_UI_ACTIONS).map { it.take(32) }.toSet(),
            range = range,
            path = (item.getIntArray(KEY_UI_PATH) ?: IntArray(0))
                .take(MAX_UI_PATH).toList(),
        )
    }

    fun uiObservationBundle(observation: com.floe.android.rootsystem.UiObservation): Bundle =
        Bundle().apply {
            putString(KEY_UI_OBSERVATION_ID, observation.observationId.take(64))
            observation.packageName?.let { putString(KEY_UI_PACKAGE, it.take(MAX_NAME)) }
            putInt(KEY_UI_WINDOW_ID, observation.windowId)
            observation.windowType?.let { putInt(KEY_UI_WINDOW_TYPE, it) }
            observation.windowTitle?.let { putString(KEY_UI_WINDOW_TITLE, it.take(200)) }
            putInt(KEY_UI_DISPLAY_ID, observation.displayId)
            observation.rootClassName?.let { putString(KEY_UI_ROOT_CLASS, it.take(200)) }
            putInt(KEY_UI_ROTATION, observation.rotation)
            putLong(KEY_UI_CAPTURED_AT, observation.capturedAtElapsed)
            putLong(KEY_UI_EXPIRES_AT, observation.expiresAtElapsed)
            putLong(KEY_UI_GENERATION, observation.generation)
            putLong(KEY_UI_USER_REVISION, observation.userInteractionRevision)
            putInt(KEY_UI_SCANNED, observation.scannedNodeCount)
            putBoolean(KEY_TRUNCATED, observation.truncated)
            putBoolean(KEY_UI_MAX_DEPTH_REACHED, observation.maxDepthReached)
            putBoolean(KEY_UI_SCAN_LIMITED, observation.scanLimited)
            putBoolean(KEY_UI_TIME_LIMITED, observation.timeLimited)
            putBoolean(KEY_UI_SELECTION_LIMITED, observation.selectionLimited)
            putBoolean(KEY_UI_TEXT_LIMITED, observation.textLimited)
            putBoolean(KEY_UI_SENSITIVE_WINDOW, observation.sensitiveWindow)
            putBoolean(KEY_UI_SENSITIVE_FIELD, observation.hasSensitiveField)
            putBoolean(KEY_UI_NAVIGATION_ONLY, observation.navigationOnly)
            putString(KEY_UI_BACKEND, observation.backend.take(32))
            putString(KEY_UI_PROVENANCE, observation.provenance.take(48))
            putParcelableArray(KEY_UI_NODES, observation.nodes.take(MAX_UI_NODES).map(::uiNodeBundle).toTypedArray())
        }

    fun uiObservation(bundle: Bundle?): com.floe.android.rootsystem.UiObservation? {
        if (bundle == null) return null
        val id = bundle.getString(KEY_UI_OBSERVATION_ID)?.take(64) ?: return null
        val array = bundleArray(bundle, KEY_UI_NODES) ?: return null
        if (array.size > MAX_UI_NODES) return null
        return com.floe.android.rootsystem.UiObservation(
            observationId = id,
            packageName = bundle.getString(KEY_UI_PACKAGE)?.take(MAX_NAME),
            windowId = bundle.getInt(KEY_UI_WINDOW_ID),
            windowType = if (bundle.containsKey(KEY_UI_WINDOW_TYPE)) {
                bundle.getInt(KEY_UI_WINDOW_TYPE)
            } else null,
            windowTitle = bundle.getString(KEY_UI_WINDOW_TITLE)?.take(200),
            displayId = bundle.getInt(KEY_UI_DISPLAY_ID),
            rootClassName = bundle.getString(KEY_UI_ROOT_CLASS)?.take(200),
            rotation = bundle.getInt(KEY_UI_ROTATION),
            capturedAtElapsed = bundle.getLong(KEY_UI_CAPTURED_AT),
            expiresAtElapsed = bundle.getLong(KEY_UI_EXPIRES_AT),
            generation = bundle.getLong(KEY_UI_GENERATION),
            userInteractionRevision = bundle.getLong(KEY_UI_USER_REVISION),
            nodes = array.mapNotNull(::parseUiNode),
            scannedNodeCount = bundle.getInt(KEY_UI_SCANNED).coerceAtLeast(0),
            truncated = bundle.getBoolean(KEY_TRUNCATED),
            maxDepthReached = bundle.getBoolean(KEY_UI_MAX_DEPTH_REACHED),
            scanLimited = bundle.getBoolean(KEY_UI_SCAN_LIMITED),
            timeLimited = bundle.getBoolean(KEY_UI_TIME_LIMITED),
            selectionLimited = bundle.getBoolean(KEY_UI_SELECTION_LIMITED),
            textLimited = bundle.getBoolean(KEY_UI_TEXT_LIMITED),
            sensitiveWindow = bundle.getBoolean(KEY_UI_SENSITIVE_WINDOW),
            hasSensitiveField = bundle.getBoolean(KEY_UI_SENSITIVE_FIELD),
            navigationOnly = bundle.getBoolean(KEY_UI_NAVIGATION_ONLY),
            backend = bundle.getString(KEY_UI_BACKEND)?.take(32) ?: "adbUiAutomation",
            provenance = bundle.getString(KEY_UI_PROVENANCE)?.take(48) ?: "adbUiAutomation",
        )
    }

    /** One already-validated typed uiAct request; text never appears in toString. */
    class UiActFields(
        val observationId: String,
        val nodeRef: String?,
        val action: com.floe.android.rootsystem.UiAction,
        val direction: String?,
        val targetPackage: String?,
        val sensitiveText: String?,
        val sensitiveTextIntent: Boolean,
    ) {
        override fun toString(): String =
            "UiActFields(observationId=$observationId, nodeRef=$nodeRef, action=$action, " +
                "direction=$direction, targetPackage=$targetPackage, " +
                "text=<redacted>, sensitiveTextIntent=$sensitiveTextIntent)"
    }

    sealed interface UiActDecode {
        data class Ok(val fields: UiActFields) : UiActDecode
        data class Failure(val code: String) : UiActDecode
    }

    /**
     * Closed decode of the appended uiAct Bundle fields exactly as the live
     * service sees them. The explicit sensitive-intent flag travels only with
     * ONE SET_TEXT payload; a payload on another action is refused instead of
     * being silently discarded. Pure seam (no Bundle), so the intent contract
     * is unit-testable without Android.
     */
    fun decodeUiActFields(
        observationId: String?,
        nodeRef: String?,
        actionWire: String?,
        direction: String?,
        targetPackage: String?,
        sensitiveText: String?,
        sensitiveTextIntent: Boolean,
        targets: Set<String>,
    ): UiActDecode {
        if (observationId != null && observationId.length > 64) {
            return UiActDecode.Failure("ui_observation_invalid")
        }
        if (nodeRef != null && nodeRef.length > 32) {
            return UiActDecode.Failure("ui_observation_invalid")
        }
        val action = com.floe.android.rootsystem.UiAction.fromWire(actionWire)
            ?: return UiActDecode.Failure("ui_action")
        if (direction != null && direction !in UI_DIRECTIONS) {
            return UiActDecode.Failure("ui_direction")
        }
        if (targetPackage != null && targetPackage !in targets) {
            return UiActDecode.Failure("target_not_authorized")
        }
        if (sensitiveText != null && sensitiveText.length > MAX_UI_SET_TEXT) {
            return UiActDecode.Failure("ui_text")
        }
        if ((sensitiveText != null || sensitiveTextIntent) &&
            action != com.floe.android.rootsystem.UiAction.SET_TEXT
        ) {
            return UiActDecode.Failure("ui_text")
        }
        if (sensitiveTextIntent && sensitiveText == null) {
            return UiActDecode.Failure("ui_text")
        }
        return UiActDecode.Ok(
            UiActFields(
                observationId = observationId ?: "",
                nodeRef = nodeRef,
                action = action,
                direction = direction,
                targetPackage = targetPackage,
                sensitiveText = sensitiveText,
                sensitiveTextIntent = sensitiveTextIntent,
            ),
        )
    }

    fun uiActResult(bundle: Bundle?): com.floe.android.rootsystem.UiActResult? {
        if (bundle == null) return null
        val action = bundle.getString(KEY_UI_ACTION)?.take(32) ?: return null
        val dispatch = runCatching {
            com.floe.android.rootsystem.UiDispatchOutcome.valueOf(
                bundle.getString(KEY_UI_DISPATCH)!!.take(24),
            )
        }.getOrNull() ?: return null
        val observation = bundle.getBundle(KEY_UI_OBSERVATION)?.let(::uiObservation)
        return com.floe.android.rootsystem.UiActResult(
            action = action,
            dispatch = dispatch,
            method = bundle.getString(KEY_UI_METHOD)?.take(32),
            screenChanged = if (bundle.containsKey(KEY_UI_SCREEN_CHANGED)) {
                bundle.getBoolean(KEY_UI_SCREEN_CHANGED)
            } else null,
            observation = observation,
            detailCode = bundle.getString(KEY_UI_DETAIL_CODE)?.take(48),
            detail = bundle.getString(KEY_UI_DETAIL)?.take(240),
        )
    }

    fun uiScreenshotInfo(bundle: Bundle?): com.floe.android.rootsystem.UiScreenshotInfo? {
        if (bundle == null) return null
        return com.floe.android.rootsystem.UiScreenshotInfo(
            screenshotId = bundle.getString(KEY_UI_SCREENSHOT_ID)?.take(64) ?: return null,
            mimeType = bundle.getString(KEY_UI_MIME)?.take(32) ?: return null,
            width = bundle.getInt(KEY_UI_WIDTH),
            height = bundle.getInt(KEY_UI_HEIGHT),
            originalWidth = bundle.getInt(KEY_UI_ORIGINAL_WIDTH),
            originalHeight = bundle.getInt(KEY_UI_ORIGINAL_HEIGHT),
            rotation = bundle.getInt(KEY_UI_ROTATION),
            displayId = bundle.getInt(KEY_UI_DISPLAY_ID),
            bytesTotal = bundle.getInt(KEY_UI_BYTES_TOTAL),
            capturedAtElapsed = bundle.getLong(KEY_UI_CAPTURED_AT),
            backend = bundle.getString(KEY_UI_BACKEND)?.take(32) ?: "adbUiAutomation",
            provenance = bundle.getString(KEY_UI_PROVENANCE)?.take(48) ?: "adbUiAutomation",
        )
    }

    fun uiScreenshotChunk(bundle: Bundle?): com.floe.android.rootsystem.UiScreenshotChunk? {
        if (bundle == null) return null
        val bytes = bundle.getByteArray(KEY_UI_CHUNK) ?: ByteArray(0)
        if (bytes.size > MAX_UI_SCREENSHOT_CHUNK) return null
        return com.floe.android.rootsystem.UiScreenshotChunk(
            bytes = bytes,
            done = bundle.getBoolean(KEY_UI_DONE),
            bytesRead = bundle.getInt(KEY_UI_BYTES_READ).coerceAtLeast(0),
        )
    }

    fun uiBackendStatus(bundle: Bundle?): com.floe.android.rootsystem.UiBackendStatus? {
        if (bundle == null) return null
        return com.floe.android.rootsystem.UiBackendStatus(
            ready = bundle.getBoolean(KEY_UI_READY),
            live = bundle.getBoolean(KEY_UI_LIVE),
            mode = bundle.getString(KEY_UI_MODE)?.take(16),
            effectiveUid = bundle.getInt(KEY_SERVER_UID, -1),
            protocolVersion = bundle.getInt(KEY_PROTOCOL, -1),
            capabilities = (bundle.getStringArray(KEY_CAPABILITIES) ?: emptyArray())
                .take(64).map { it.take(48) }.toSet(),
            screenSupport = bundle.getString(KEY_UI_SCREEN_SUPPORT)?.take(16) ?: "none",
            reason = bundle.getString(KEY_UI_REASON)?.take(48),
            userInteractionElapsedRealtimeMillis = bundle.getLong(KEY_UI_USER_INTERACTION, -1L),
            observationTtlMillis = bundle.getLong(KEY_UI_TTL, 0L),
            maxNodes = bundle.getInt(KEY_UI_MAX_NODE_LIMIT, 0),
        )
    }

    /** Reply codec for the typed appops set receipt (scope-aware). */
    fun appOpsSetResult(bundle: Bundle?): com.floe.android.rootsystem.AppOpsSetReceipt? {
        val item = bundle?.getBundle(KEY_PACKAGE_RESULT) ?: return null
        val scope = if (item.containsKey(KEY_APPOP_SCOPE)) {
            com.floe.android.rootsystem.policy.PermissionOpsPolicy.appOpScope(
                item.getString(KEY_APPOP_SCOPE),
            ) ?: return null
        } else {
            com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_PACKAGE
        }
        return com.floe.android.rootsystem.AppOpsSetReceipt(
            packageName = item.getString(KEY_PACKAGE_NAME)?.take(MAX_NAME) ?: return null,
            userId = item.getInt(KEY_USER_ID),
            operation = item.getString(KEY_APPOP_OPERATION)?.take(32) ?: return null,
            opName = item.getString(KEY_OP_NAME)?.take(64) ?: return null,
            scope = scope,
            resolvedUid = item.getInt(KEY_RESOLVED_UID, -1),
            overrideBefore = nullableString(item, KEY_OVERRIDE_BEFORE, 16),
            uidBefore = nullableString(item, KEY_UID_BEFORE, 16),
            defaultBefore = nullableString(item, KEY_DEFAULT_BEFORE, 16),
            effectiveBefore = item.getString(KEY_EFFECTIVE_BEFORE)?.take(16)
                ?: return null,
            requestedMode = item.getString(KEY_REQUESTED_MODE)?.take(16) ?: return null,
            overrideAfter = nullableString(item, KEY_OVERRIDE_MODE, 16),
            uidAfter = nullableString(item, KEY_UID_AFTER, 16),
            effectiveAfter = item.getString(KEY_EFFECTIVE_MODE)?.take(16) ?: return null,
            succeeded = item.getBoolean(KEY_SUCCEEDED),
            detailCode = item.getString(KEY_DETAIL_CODE)?.take(48) ?: return null,
            failureDetail = item.getString(KEY_FAILURE_DETAIL)?.take(96),
        )
    }
}