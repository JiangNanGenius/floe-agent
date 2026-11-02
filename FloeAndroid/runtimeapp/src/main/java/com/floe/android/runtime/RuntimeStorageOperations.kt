// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.content.Context
import android.os.Process
import com.floe.android.linuxruntime.install.RootfsInstaller
import com.floe.android.linuxruntime.supervision.*
import com.floe.android.runtimeipc.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Authenticated host maintenance only; no guest, native root or model tool
 * is started by an inventory. Cleanup reuses the installer's marked orphan
 * sweep, preserving verified archives, installed layers and every workspace. */
internal class RuntimeStorageOperations(private val context: Context) {
    fun execute(request: RuntimeWire.Request, idle: () -> Boolean, cancelled: () -> Boolean): JSONObject {
        require(request.payload.length() == 0)
        return when (request.operation) {
            RuntimeWire.STORAGE_INVENTORY -> inventory()
            RuntimeWire.STORAGE_CLEANUP -> cleanup(idle, cancelled)
            else -> error("Unknown storage operation")
        }
    }

    private fun inventory(): JSONObject {
        val meter = StorageUsageMeter()
        val root = context.filesDir
        val rows = JSONArray()
        for ((id, file) in listOf(
            "runtimeBase" to File(root, "Base"),
            "runtimeEnvironments" to File(root, "Environments"),
            "runtimeWorkspaces" to File(root, "Workspaces"),
            "runtimeInstaller" to File(root, "Installer"),
            "runtimeOther" to root,
            "runtimeCache" to context.cacheDir,
        )) {
            val excluded = if (id == "runtimeOther") setOf("Base", "Environments", "Workspaces", "Installer") else emptySet()
            rows.put(storageUsageJSON(id, meter.measure(file, excluded)))
        }
        return JSONObject().put("status", "measured").put("rows", rows)
    }

    private fun censusIsIdle(): Boolean {
        val pair = RuntimePackages.forRuntime(context.packageName)
        val reader = AndroidPackageMetadataReader(context)
        val core = reader.read(pair.core) ?: return false
        val runtime = reader.read(pair.runtime) ?: return false
        val check = RuntimeUidBoundary.validate(pair.core, core.signatureSha256.firstOrNull() ?: return false,
            pair.runtime, runtime.signatureSha256.firstOrNull() ?: return false,
            Process.myUid(), Process.myPid(), reader)
        val boundary = (check as? BoundaryCheck.Accepted)?.boundary ?: return false
        return ProcCensus(boundary, LinuxProcReader, PosixSignalBoundary()).snapshot().isCleanlyQuiescent
    }

    private fun cleanup(idle: () -> Boolean, cancelled: () -> Boolean): JSONObject {
        fun deferred(reason: String) = JSONObject().put("status", "deferred")
            .put("reason", reason).put("reclaimedBytes", JSONObject.NULL)
        if (cancelled() || !idle()) return deferred("activeWork")
        if (!censusIsIdle()) return deferred("quiescenceUnknown")
        val installerRoot = File(context.filesDir, "Installer")
        val before = StorageUsageMeter().measure(installerRoot)
        // Shared inodes, symlinks, inaccessible entries or an incomplete scan
        // cannot justify deleting or claiming reclaimed physical bytes.
        if (!before.complete || before.sharedFiles != 0 || before.retainedSpecialEntries != 0) return deferred("inventoryIncomplete")
        if (cancelled() || !idle()) return deferred("activeWork")
        val sweep = try {
            RootfsInstaller(installerRoot.absoluteFile).sweepStaleWorkspace(24L * 60 * 60 * 1000)
        } catch (_: Exception) {
            return JSONObject().put("status", "partial").put("reason", "cleanupIncomplete")
                .put("reclaimedBytes", JSONObject.NULL)
        }
        val after = StorageUsageMeter().measure(installerRoot)
        val beforeBytes = before.allocatedBytes
        val afterBytes = after.allocatedBytes
        val freed = if (after.complete && after.sharedFiles == 0 &&
            after.retainedSpecialEntries == 0 && beforeBytes != null && afterBytes != null) {
            maxOf(0L, beforeBytes - afterBytes)
        } else null
        return JSONObject().put("status", if (freed != null) "completed" else "partial")
            .put("reclaimedBytes", freed ?: JSONObject.NULL)
            .put("retainedEntries", sweep.skippedForeign)
            .put("preserved", JSONArray(listOf("verifiedArchives", "installedEnvironments", "workspaceData", "recoveryData")))
    }
}
