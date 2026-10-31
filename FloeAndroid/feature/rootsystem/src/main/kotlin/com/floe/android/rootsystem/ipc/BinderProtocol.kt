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

    const val VERSION = 1
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
    const val KEY_USER_ID = "userId"
    const val KEY_EXPECTED_PID = "expectedPid"

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
    }

    fun parseGrant(bundle: Bundle?): GrantRequest? {
        if (bundle == null) return null
        val ids = bundle.getStringArray(KEY_SCOPE_IDS) ?: return null
        val paths = bundle.getStringArray(KEY_SCOPE_PATHS) ?: return null
        val writable = bundle.getBooleanArray(KEY_SCOPE_WRITABLE) ?: return null
        val ops = bundle.getStringArray(KEY_OPERATIONS) ?: return null
        if (ids.size != paths.size || ids.size != writable.size) return null
        if (ids.size !in 1..8 || ops.size !in 1..SystemOperation.entries.size) return null
        val operations = LinkedHashSet<SystemOperation>()
        for (name in ops) {
            operations.add(SystemOperation.entries.firstOrNull { it.name == name } ?: return null)
        }
        return GrantRequest(
            grantId = bundle.getString(KEY_GRANT_ID) ?: return null,
            taskId = bundle.getString(KEY_TASK_ID) ?: return null,
            runId = bundle.getString(KEY_RUN_ID) ?: return null,
            epoch = bundle.getLong(KEY_EPOCH),
            expiresAtMillis = bundle.getLong(KEY_EXPIRES_AT),
            scopes = ids.indices.map { ScopeRoot(ids[it], paths[it], writable[it]) },
            operations = operations,
            packageManagementAllowed = bundle.getBoolean(KEY_PACKAGE_MANAGEMENT),
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
}
