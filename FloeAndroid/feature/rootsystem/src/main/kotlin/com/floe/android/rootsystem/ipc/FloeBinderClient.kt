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
    ): RootResult<PackageQuery> {
        val request = request(claim, SystemOperation.PACKAGE_QUERY, null).apply {
            if (packageName != null) putString(BinderProtocol.KEY_PACKAGE_NAME, packageName)
            putBoolean(BinderProtocol.KEY_INCLUDE_SYSTEM, includeSystem)
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
            "protected", "protected_target" -> RootResult.Denied(code)
            "service_died", "unavailable" -> RootResult.Unavailable(code)
            else -> RootResult.Failed(code)
        }
    }
}
