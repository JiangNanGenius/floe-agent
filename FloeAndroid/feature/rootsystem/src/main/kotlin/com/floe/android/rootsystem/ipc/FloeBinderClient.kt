// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import android.os.Bundle
import android.os.IBinder
import com.floe.android.rootsystem.AccessActionResult
import com.floe.android.rootsystem.DeleteReceipt
import com.floe.android.rootsystem.FileEntry
import com.floe.android.rootsystem.FileRead
import com.floe.android.rootsystem.FileWriteReceipt
import com.floe.android.rootsystem.GrantReceipt
import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.MoveReceipt
import com.floe.android.rootsystem.NetworkDiagnostics
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.PackageManagementReceipt
import com.floe.android.rootsystem.PackageQuery
import com.floe.android.rootsystem.PacketCaptureChunk
import com.floe.android.rootsystem.PacketCaptureInfo
import com.floe.android.rootsystem.ProcessRecord
import com.floe.android.rootsystem.RootResult
import com.floe.android.rootsystem.ServiceRecord
import com.floe.android.rootsystem.SystemOperation

/** App-side typed wrapper. Binder exceptions are mapped, never converted to success. */
internal class FloeBinderClient(private val binder: IBinder) {

    private val service: IFloeSystemService? = IFloeSystemService.Stub.asInterface(binder)

    fun isAlive(): Boolean = binder.pingBinder()

    fun describe(): Bundle? = try {
        service?.describe()
    } catch (_: Throwable) {
        null
    }

    /** Capability strings advertised by the live peer; empty when unknown. */
    fun capabilities(): Set<String> = try {
        describe()
            ?.getStringArray(BinderProtocol.KEY_CAPABILITIES)
            ?.toSet()
            .orEmpty()
    } catch (_: Throwable) {
        emptySet()
    }

    fun registerGrant(request: GrantRequest): RootResult<GrantReceipt> = try {
        val reply = service?.registerGrant(BinderProtocol.grantBundle(request))
        if (BinderProtocol.isOk(reply)) {
            RootResult.Ok(
                GrantReceipt(
                    grantId = reply?.getString(BinderProtocol.KEY_GRANT_ID) ?: request.grantId,
                    registeredAtMillis = System.currentTimeMillis(),
                    expiresAtMillis = request.expiresAtMillis,
                ),
            )
        } else {
            RootResult.Denied(BinderProtocol.code(reply) ?: "grant")
        }
    } catch (e: Throwable) {
        RootResult.Unavailable("service_died")
    }

    fun revokeGrant(grantId: String): AccessActionResult = try {
        service?.revokeGrant(grantId)
        AccessActionResult.Ok
    } catch (_: Throwable) {
        AccessActionResult.Unavailable("service_died")
    }

    fun revokeAllGrants(): AccessActionResult = try {
        service?.revokeAllGrants()
        AccessActionResult.Ok
    } catch (_: Throwable) {
        AccessActionResult.Unavailable("service_died")
    }

    fun fileList(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        maxEntries: Int,
    ): RootResult<List<FileEntry>> {
        val request = request(claim, SystemOperation.FILE_LIST, scopeId).apply {
            putString(BinderProtocol.KEY_RELATIVE_PATH, relativePath)
            putInt(BinderProtocol.KEY_MAX_ENTRIES, maxEntries)
        }
        return try {
            val reply = service?.fileList(request)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(BinderProtocol.entries(reply) ?: emptyList())
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun fileRead(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        offset: Long,
        maxBytes: Int,
    ): RootResult<FileRead> {
        val request = request(claim, SystemOperation.FILE_READ, scopeId).apply {
            putString(BinderProtocol.KEY_RELATIVE_PATH, relativePath)
            putLong(BinderProtocol.KEY_OFFSET, offset)
            putInt(BinderProtocol.KEY_MAX_BYTES, maxBytes)
        }
        return try {
            val reply = service?.fileRead(request)
            val data = reply?.getByteArray(BinderProtocol.KEY_DATA)
            if (BinderProtocol.isOk(reply) && data != null) {
                RootResult.Ok(FileRead(data, reply.getBoolean(BinderProtocol.KEY_TRUNCATED, false)))
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun fileWrite(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        data: ByteArray,
        overwrite: Boolean,
    ): RootResult<FileWriteReceipt> {
        if (data.size > BinderProtocol.MAX_WRITE_BYTES) {
            return RootResult.Denied("write_too_large")
        }
        val request = request(claim, SystemOperation.FILE_WRITE, scopeId).apply {
            putString(BinderProtocol.KEY_RELATIVE_PATH, relativePath)
            putBoolean(BinderProtocol.KEY_OVERWRITE, overwrite)
        }
        return try {
            val reply = service?.fileWrite(request, data)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(
                    FileWriteReceipt(
                        relativePath = relativePath,
                        bytesWritten = reply?.getInt(BinderProtocol.KEY_BYTES_WRITTEN, data.size)
                            ?: data.size,
                        atomic = reply?.getBoolean(BinderProtocol.KEY_ATOMIC, false) ?: false,
                    ),
                )
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun fileMove(
        claim: OperationClaim,
        scopeId: String,
        fromRelativePath: String,
        toRelativePath: String,
        overwrite: Boolean,
    ): RootResult<MoveReceipt> {
        val request = request(claim, SystemOperation.FILE_MOVE, scopeId).apply {
            putString(BinderProtocol.KEY_FROM_PATH, fromRelativePath)
            putString(BinderProtocol.KEY_TO_PATH, toRelativePath)
            putBoolean(BinderProtocol.KEY_OVERWRITE, overwrite)
        }
        return try {
            val reply = service?.fileMove(request)
            if (BinderProtocol.isOk(reply)) RootResult.Ok(MoveReceipt(fromRelativePath, toRelativePath))
            else failed(reply)
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun fileDelete(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        recursive: Boolean,
    ): RootResult<DeleteReceipt> {
        val request = request(claim, SystemOperation.FILE_DELETE, scopeId).apply {
            putString(BinderProtocol.KEY_RELATIVE_PATH, relativePath)
            putBoolean(BinderProtocol.KEY_RECURSIVE, recursive)
        }
        return try {
            val reply = service?.fileDelete(request)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(DeleteReceipt(reply?.getInt(BinderProtocol.KEY_DELETED, 0) ?: 0))
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun processQuery(
        claim: OperationClaim,
        filter: String?,
        maxEntries: Int,
    ): RootResult<List<ProcessRecord>> {
        val request = request(claim, SystemOperation.PROCESS_QUERY, null).apply {
            if (filter != null) putString(BinderProtocol.KEY_FILTER, filter)
            putInt(BinderProtocol.KEY_MAX_ENTRIES, maxEntries)
        }
        return try {
            val reply = service?.processQuery(request)
            if (BinderProtocol.isOk(reply)) RootResult.Ok(BinderProtocol.processes(reply) ?: emptyList())
            else failed(reply)
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun serviceQuery(claim: OperationClaim, maxEntries: Int): RootResult<List<ServiceRecord>> {
        val request = request(claim, SystemOperation.SERVICE_QUERY, null).apply {
            putInt(BinderProtocol.KEY_MAX_ENTRIES, maxEntries)
        }
        return try {
            val reply = service?.serviceQuery(request)
            if (BinderProtocol.isOk(reply)) RootResult.Ok(BinderProtocol.services(reply) ?: emptyList())
            else failed(reply)
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun packageQuery(
        claim: OperationClaim,
        packageName: String?,
        includeSystem: Boolean,
        maxEntries: Int,
        includeUninstalled: Boolean = false,
    ): RootResult<PackageQuery> {
        val request = request(claim, SystemOperation.PACKAGE_QUERY, null).apply {
            if (packageName != null) putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putBoolean(BinderProtocol.KEY_INCLUDE_SYSTEM, includeSystem)
            putBoolean(BinderProtocol.KEY_INCLUDE_UNINSTALLED, includeUninstalled)
            putInt(BinderProtocol.KEY_MAX_ENTRIES, maxEntries)
        }
        return try {
            val reply = service?.packageQuery(request)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(BinderProtocol.packages(reply) ?: PackageQuery(emptyList(), false))
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun networkDiagnostics(claim: OperationClaim): RootResult<NetworkDiagnostics> {
        val request = request(claim, SystemOperation.NETWORK_DIAGNOSTICS, null)
        return try {
            val reply = service?.networkDiagnostics(request)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(BinderProtocol.network(reply) ?: NetworkDiagnostics(emptyList(), emptyList(), emptyList()))
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun packetCaptureStart(
        claim: OperationClaim,
        helperId: String,
        interfaceName: String,
        snaplen: Int,
        maxBytes: Long,
        maxMillis: Long,
    ): RootResult<PacketCaptureInfo> {
        val request = request(claim, SystemOperation.PACKET_CAPTURE, null).apply {
            putString(BinderProtocol.KEY_CAPTURE_MODE, "start")
            putString(BinderProtocol.KEY_HELPER_ID, helperId)
            putString(BinderProtocol.KEY_INTERFACE_NAME, interfaceName)
            putInt(BinderProtocol.KEY_SNAPLEN, snaplen)
            putLong(BinderProtocol.KEY_MAX_BYTES, maxBytes)
            putLong(BinderProtocol.KEY_MAX_MILLIS, maxMillis)
        }
        return try {
            val reply = service?.packetCapture(request)
            if (BinderProtocol.isOk(reply)) {
                val id = reply?.getString(BinderProtocol.KEY_CAPTURE_ID)
                val helper = reply?.getString(BinderProtocol.KEY_HELPER_PATH)
                if (id.isNullOrBlank() || helper.isNullOrBlank()) {
                    RootResult.Failed("capture_reply")
                } else {
                    RootResult.Ok(PacketCaptureInfo(id, helper))
                }
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun packetCaptureRead(
        claim: OperationClaim,
        captureId: String,
        maxBytes: Int,
    ): RootResult<PacketCaptureChunk> {
        val request = request(claim, SystemOperation.PACKET_CAPTURE, null).apply {
            putString(BinderProtocol.KEY_CAPTURE_MODE, "read")
            putString(BinderProtocol.KEY_CAPTURE_ID, captureId)
            putInt(BinderProtocol.KEY_MAX_BYTES, maxBytes)
        }
        return try {
            val reply = service?.packetCapture(request)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(
                    PacketCaptureChunk(
                        bytes = reply?.getByteArray(BinderProtocol.KEY_CAPTURE_CHUNK) ?: ByteArray(0),
                        done = reply?.getBoolean(BinderProtocol.KEY_CAPTURE_DONE, false) == true,
                        bytesRead = reply?.getLong(BinderProtocol.KEY_BYTES_READ, 0) ?: 0,
                        endReason = reply?.getString(BinderProtocol.KEY_CAPTURE_END),
                    ),
                )
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun packetCaptureStop(
        claim: OperationClaim,
        captureId: String,
    ): RootResult<PacketCaptureChunk> {
        val request = request(claim, SystemOperation.PACKET_CAPTURE, null).apply {
            putString(BinderProtocol.KEY_CAPTURE_MODE, "stop")
            putString(BinderProtocol.KEY_CAPTURE_ID, captureId)
        }
        return try {
            val reply = service?.packetCapture(request)
            if (BinderProtocol.isOk(reply)) {
                RootResult.Ok(
                    PacketCaptureChunk(
                        bytes = reply?.getByteArray(BinderProtocol.KEY_CAPTURE_CHUNK) ?: ByteArray(0),
                        done = reply?.getBoolean(BinderProtocol.KEY_CAPTURE_DONE, false) == true,
                        bytesRead = reply?.getLong(BinderProtocol.KEY_BYTES_READ, 0) ?: 0,
                        endReason = reply?.getString(BinderProtocol.KEY_CAPTURE_END),
                    ),
                )
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun managePackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<PackageManagementReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_FORCE_STOP, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
        }
        return try {
            val reply = service?.managePackage(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.packageResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun installPackage(
        claim: OperationClaim,
        stagedApkPath: String,
        userId: Int,
        binding: com.floe.android.rootsystem.StagedApkBinding =
            com.floe.android.rootsystem.StagedApkBinding(null, -1L, null),
    ): RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_INSTALL, null).apply {
            putString(BinderProtocol.KEY_APK_PATH, stagedApkPath)
            putInt(BinderProtocol.KEY_USER_ID, userId)
            if (binding.expectedSha256 != null) {
                putString(BinderProtocol.KEY_EXPECTED_SHA256, binding.expectedSha256)
            }
            if (binding.expectedSizeBytes > 0) {
                putLong(BinderProtocol.KEY_EXPECTED_SIZE, binding.expectedSizeBytes)
            }
            if (binding.expectedPackageName != null) {
                putString(BinderProtocol.KEY_EXPECTED_PACKAGE, binding.expectedPackageName)
            }
        }
        return try {
            val reply = service?.installPackage(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.packageLifecycleResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun uninstallPackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_UNINSTALL, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
        }
        return try {
            val reply = service?.uninstallPackage(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.packageLifecycleResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun stageApk(
        claim: OperationClaim,
        sourcePath: String,
    ): RootResult<com.floe.android.rootsystem.StagedCopyReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_STAGE, null).apply {
            putString(BinderProtocol.KEY_SOURCE_PATH, sourcePath)
        }
        return try {
            val reply = service?.stageApk(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.stagedCopyResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun setPackageEnabled(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
        state: String,
    ): RootResult<com.floe.android.rootsystem.PackageStateReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_SET_ENABLED, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
            putString(BinderProtocol.KEY_PACKAGE_STATE, state)
        }
        return try {
            val reply = service?.setPackageEnabled(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.packageStateResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun removePackageForUser(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_REMOVE_FOR_USER, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
        }
        return try {
            val reply = service?.removePackageForUser(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.packageLifecycleResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun restorePackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt> {
        val request = request(claim, SystemOperation.PACKAGE_RESTORE, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
        }
        return try {
            val reply = service?.restorePackage(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.packageLifecycleResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun releaseStagedApk(sha256: String): AccessActionResult = try {
        val reply = service?.releaseStagedApk(Bundle().apply {
            putString(BinderProtocol.KEY_SHA256, sha256)
        })
        if (BinderProtocol.isOk(reply)) AccessActionResult.Ok else AccessActionResult.Failed(
            BinderProtocol.code(reply) ?: "staged_release",
        )
    } catch (_: Throwable) {
        AccessActionResult.Unavailable("service_died")
    }

    // -------------------------------------------------- permissions/appops

    fun queryPermissions(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.PermissionQueryResult> {
        val request = request(claim, SystemOperation.PERMISSIONS_QUERY, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
        }
        return try {
            val reply = service?.queryPermissions(request)
            if (BinderProtocol.isOk(reply)) {
                val result = com.floe.android.rootsystem.PermissionQueryResult(
                    packageName = reply?.getString(BinderProtocol.KEY_PACKAGE_NAME)?.take(BinderProtocol.MAX_NAME)
                        ?: return RootResult.Failed("receipt"),
                    userId = reply?.getInt(BinderProtocol.KEY_USER_ID, userId) ?: userId,
                    permissions = BinderProtocol.permissionStates(reply) ?: emptyList(),
                )
                RootResult.Ok(result)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun managePermission(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
        permission: String,
        action: String,
    ): RootResult<com.floe.android.rootsystem.PermissionSetReceipt> {
        val request = request(claim, SystemOperation.PERMISSIONS_MANAGE, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
            putString(BinderProtocol.KEY_PERMISSION_NAME, permission)
            putString(BinderProtocol.KEY_PERMISSION_ACTION, action)
        }
        return try {
            val reply = service?.managePermissions(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.permissionSetResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun queryAppOps(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
    ): RootResult<com.floe.android.rootsystem.AppOpsQueryResult> {
        val request = request(claim, SystemOperation.APP_OPS_QUERY, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
        }
        return try {
            val reply = service?.queryAppOps(request)
            if (BinderProtocol.isOk(reply)) {
                val result = com.floe.android.rootsystem.AppOpsQueryResult(
                    packageName = reply?.getString(BinderProtocol.KEY_PACKAGE_NAME)?.take(BinderProtocol.MAX_NAME)
                        ?: return RootResult.Failed("receipt"),
                    userId = reply?.getInt(BinderProtocol.KEY_USER_ID, userId) ?: userId,
                    operations = BinderProtocol.appOpsStates(reply) ?: emptyList(),
                )
                RootResult.Ok(result)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun manageAppOps(
        claim: OperationClaim,
        packageName: String,
        userId: Int,
        operation: String,
        mode: String,
        scope: String = com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_PACKAGE,
    ): RootResult<com.floe.android.rootsystem.AppOpsSetReceipt> {
        val request = request(claim, SystemOperation.APP_OPS_MANAGE, null).apply {
            putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putInt(BinderProtocol.KEY_USER_ID, userId)
            putString(BinderProtocol.KEY_APPOP_OPERATION, operation)
            putString(BinderProtocol.KEY_APPOP_MODE, mode)
            // The scope token is closed ("package"/"uid"); the UID itself is
            // resolved by the service from the live package identity, never
            // accepted from the wire.
            putString(BinderProtocol.KEY_APPOP_SCOPE, scope)
        }
        return try {
            val reply = service?.manageAppOps(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = BinderProtocol.appOpsSetResult(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun readSettings(
        claim: OperationClaim,
        namespace: String,
        key: String,
    ): RootResult<com.floe.android.rootsystem.SettingReadResult> {
        val request = request(claim, SystemOperation.SETTINGS_READ, null).apply {
            putAll(SettingsProtocol.readRequest(namespace, key))
        }
        return try {
            val reply = service?.readSettings(request)
            if (BinderProtocol.isOk(reply)) {
                val result = SettingsProtocol.readResult(reply)
                if (result == null) RootResult.Failed("receipt") else RootResult.Ok(result)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun writeSettings(
        claim: OperationClaim,
        changes: List<com.floe.android.rootsystem.SettingsChange>,
    ): RootResult<com.floe.android.rootsystem.SettingsBatchReceipt> {
        val request = request(claim, SystemOperation.SETTINGS_WRITE, null).apply {
            putParcelableArray(
                SettingsProtocol.KEY_SETTINGS_CHANGES,
                SettingsProtocol.changeBundles(changes),
            )
        }
        return try {
            val reply = service?.writeSettings(request)
            if (BinderProtocol.isOk(reply)) {
                val receipt = SettingsProtocol.batchReceipt(reply)
                if (receipt == null) RootResult.Failed("receipt") else RootResult.Ok(receipt)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    // ------------------------------------------------------------ typed UI

    fun uiStatus(): RootResult<com.floe.android.rootsystem.UiBackendStatus> = try {
        val reply = service?.uiStatus(Bundle())
        if (BinderProtocol.isOk(reply)) {
            val status = BinderProtocol.uiBackendStatus(reply)
            if (status == null) RootResult.Failed("ui_status") else RootResult.Ok(status)
        } else {
            failed(reply)
        }
    } catch (_: Throwable) {
        RootResult.Unavailable("service_died")
    }

    fun uiObserve(
        claim: OperationClaim,
        request: com.floe.android.rootsystem.UiObserveRequest,
    ): RootResult<com.floe.android.rootsystem.UiObservation> {
        val bundle = request(claim, SystemOperation.UI_OBSERVE, null).apply {
            putInt(BinderProtocol.KEY_UI_MAX_NODES, request.maxNodes)
            putInt(BinderProtocol.KEY_UI_MAX_DEPTH, request.maxDepth)
            putBoolean(BinderProtocol.KEY_UI_INCLUDE_INVISIBLE, request.includeInvisible)
            putInt(BinderProtocol.KEY_UI_TEXT_BUDGET, request.textBudgetChars)
        }
        return try {
            val reply = service?.uiObserve(bundle)
            if (BinderProtocol.isOk(reply)) {
                val observation = reply?.getBundle(BinderProtocol.KEY_UI_OBSERVATION)
                    ?.let(BinderProtocol::uiObservation)
                if (observation == null) RootResult.Failed("ui_observation")
                else RootResult.Ok(observation)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun uiAct(
        claim: OperationClaim,
        request: com.floe.android.rootsystem.UiActRequest,
    ): RootResult<com.floe.android.rootsystem.UiActResult> {
        val bundle = request(claim, SystemOperation.UI_ACT, null).apply {
            putString(BinderProtocol.KEY_UI_OBSERVATION_ID, request.observationId)
            if (request.nodeRef != null) {
                putString(BinderProtocol.KEY_UI_NODE_REF, request.nodeRef)
            }
            putString(BinderProtocol.KEY_UI_ACTION, request.action.wireName)
            if (request.direction != null) {
                putString(BinderProtocol.KEY_UI_DIRECTION, request.direction)
            }
            if (request.targetPackage != null) {
                putString(BinderProtocol.KEY_PACKAGE_NAME, request.targetPackage)
            }
            if (request.sensitiveText != null) {
                putString(BinderProtocol.KEY_UI_SENSITIVE_TEXT, request.sensitiveText)
            }
            if (request.sensitiveTextIntent) {
                // Appended v4 extra; absent means the ordinary-text path.
                putBoolean(BinderProtocol.KEY_UI_SENSITIVE_TEXT_INTENT, true)
            }
        }
        return try {
            val reply = service?.uiAct(bundle)
            if (BinderProtocol.isOk(reply)) {
                val result = BinderProtocol.uiActResult(reply)
                if (result == null) RootResult.Failed("ui_act") else RootResult.Ok(result)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun uiScreenshotBegin(
        claim: OperationClaim,
        request: com.floe.android.rootsystem.UiScreenshotRequest,
    ): RootResult<com.floe.android.rootsystem.UiScreenshotInfo> {
        val bundle = request(claim, SystemOperation.UI_SCREENSHOT, null).apply {
            putString(BinderProtocol.KEY_UI_MODE, "begin")
            request.observationId?.let {
                putString(BinderProtocol.KEY_UI_OBSERVATION_ID, it)
            }
            putInt(BinderProtocol.KEY_MAX_BYTES, request.maxBytes)
            putInt(BinderProtocol.KEY_UI_MAX_DIMENSION, request.maxDimension)
            putInt(BinderProtocol.KEY_UI_QUALITY, request.quality)
        }
        return try {
            val reply = service?.uiScreenshot(bundle)
            if (BinderProtocol.isOk(reply)) {
                val info = BinderProtocol.uiScreenshotInfo(reply)
                if (info == null) RootResult.Failed("ui_screenshot") else RootResult.Ok(info)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun uiScreenshotRead(
        claim: OperationClaim,
        screenshotId: String,
        offset: Int,
        maxBytes: Int,
    ): RootResult<com.floe.android.rootsystem.UiScreenshotChunk> {
        val bundle = request(claim, SystemOperation.UI_SCREENSHOT, null).apply {
            putString(BinderProtocol.KEY_UI_MODE, "read")
            putString(BinderProtocol.KEY_UI_SCREENSHOT_ID, screenshotId)
            putInt(BinderProtocol.KEY_OFFSET, offset)
            putInt(BinderProtocol.KEY_MAX_BYTES, maxBytes)
        }
        return try {
            val reply = service?.uiScreenshot(bundle)
            if (BinderProtocol.isOk(reply)) {
                val chunk = BinderProtocol.uiScreenshotChunk(reply)
                if (chunk == null) RootResult.Failed("ui_screenshot") else RootResult.Ok(chunk)
            } else {
                failed(reply)
            }
        } catch (_: Throwable) {
            RootResult.Unavailable("service_died")
        }
    }

    fun uiScreenshotClose(
        claim: OperationClaim,
        screenshotId: String,
    ): AccessActionResult = try {
        val reply = service?.uiScreenshot(
            request(claim, SystemOperation.UI_SCREENSHOT, null).apply {
                putString(BinderProtocol.KEY_UI_MODE, "close")
                putString(BinderProtocol.KEY_UI_SCREENSHOT_ID, screenshotId)
            },
        )
        if (BinderProtocol.isOk(reply)) AccessActionResult.Ok
        else AccessActionResult.Failed(BinderProtocol.code(reply) ?: "ui_screenshot")
    } catch (_: Throwable) {
        AccessActionResult.Unavailable("service_died")
    }

    fun uiCancel(claim: OperationClaim): AccessActionResult = try {
        val reply = service?.uiCancel(request(claim, SystemOperation.UI_CANCEL, null))
        if (BinderProtocol.isOk(reply)) AccessActionResult.Ok
        else AccessActionResult.Failed(BinderProtocol.code(reply) ?: "ui_cancel")
    } catch (_: Throwable) {
        AccessActionResult.Unavailable("service_died")
    }

    fun cancel(requestId: String) {
        try {
            service?.cancel(requestId)
        } catch (_: Throwable) {
        }
    }

    fun stopOwnedService(expectedPid: Int): AccessActionResult = try {
        service?.stopOwnedService(Bundle().apply {
            putInt(BinderProtocol.KEY_EXPECTED_PID, expectedPid)
        })
        AccessActionResult.Ok
    } catch (_: Throwable) {
        AccessActionResult.Unavailable("service_died")
    }

    private fun request(
        claim: OperationClaim,
        operation: SystemOperation,
        scopeId: String?,
    ): Bundle = BinderProtocol.claimBundle(claim, operation).apply {
        if (scopeId != null) putString(BinderProtocol.KEY_SCOPE_ID, scopeId)
    }

    private fun <T> failed(bundle: Bundle?): RootResult<T> {
        val code = BinderProtocol.code(bundle) ?: "operation"
        return when (code) {
            "caller", "denied", "expired", "revoked", "fenced", "epoch", "task", "run",
            "operation", "management", "scope_unknown", "scope_read_only",
            "scope_not_writable", "scope_forbidden", "scope_floe_private",
            "protected_ancestor", "cancelled",
            "protected", "protected_target", "system_package",
            "not_system_package", "protected_role", "target_not_authorized",
            "cross_user_unsupported",
            "permission", "permission_action", "permission_not_declared",
            "permission_protected", "permission_unknown",
            "appop_operation", "appop_mode", "shared_uid_refused",
            "ui_scope", "ui_target_required", "ui_target_not_authorized",
            "ui_observation_invalid", "ui_dispatch_rejected", "rotation_changed",
            "locked", "ui_screenshot_scope" -> RootResult.Denied(code)
            "service_died", "unavailable", "ui_automation_unavailable", "ui_not_ready",
            "ui_closed" -> RootResult.Unavailable(code)
            else -> RootResult.Failed(code)
        }
    }
}
