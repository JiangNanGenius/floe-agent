// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.storage

import android.content.Context
import android.os.SystemClock
import com.floe.android.runtimeipc.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

data class StorageSettingsRow(val id: String, val usage: StorageUsageMeter.Usage)
data class StorageSettingsState(
    val busy: Boolean = false,
    val rows: List<StorageSettingsRow> = emptyList(),
    val runtimeState: String = "notMeasured",
    val cleanupState: String? = null,
    val reclaimedBytes: Long? = null,
)

/** Application-owned Settings work; hiding the sheet never cancels a cleanup
 * or drops the authenticated runtime binding during an accepted operation. */
class StorageSettingsHost(context: Context, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val serial = Mutex()
    private val mutableState = MutableStateFlow(StorageSettingsState())
    val state: StateFlow<StorageSettingsState> = mutableState

    fun refresh() = launch(cleanup = false)
    fun cleanUnusedTemporaries() = launch(cleanup = true)

    private fun launch(cleanup: Boolean) {
        if (!serial.tryLock()) return
        mutableState.value = mutableState.value.copy(busy = true)
        scope.launch(Dispatchers.IO) {
            try {
                val appRows = appInventory()
                var runtimeState = "unavailable"
                var cleanupState: String? = if (cleanup) "unavailable" else mutableState.value.cleanupState
                var reclaimed = if (cleanup) null else mutableState.value.reclaimedBytes
                var runtimeRows = emptyList<StorageSettingsRow>()
                val client = RuntimeConnection(context)
                try {
                    client.connect().get(15, TimeUnit.SECONDS)
                    val status = result(client.exchange("status"))
                    if (status.optBoolean("active") || status.optBoolean("stopping")) {
                        runtimeState = "activeWork"
                        if (cleanup) cleanupState = "activeWork"
                    } else {
                        if (cleanup) {
                            val receipt = complete(client, client.exchange(RuntimeWire.STORAGE_CLEANUP))
                            cleanupState = if (receipt.optString("status") == "deferred") {
                                receipt.optString("reason", "deferred")
                            } else receipt.optString("status", "unavailable")
                            reclaimed = if (receipt.isNull("reclaimedBytes")) null else receipt.getLong("reclaimedBytes")
                        }
                        val inventory = complete(client, client.exchange(RuntimeWire.STORAGE_INVENTORY))
                        runtimeRows = decodeRows(inventory)
                        runtimeState = "measured"
                    }
                } catch (_: Exception) {
                    // Older/missing components, lost binding and bad receipts
                    // remain unknown; no guest/host fallback and no retry.
                    runtimeState = "unavailable"
                } finally {
                    client.close()
                }
                mutableState.value = StorageSettingsState(false, appRows + runtimeRows,
                    runtimeState, cleanupState, reclaimed)
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(busy = false,
                    runtimeState = "unavailable", cleanupState = if (cleanup) "partial" else mutableState.value.cleanupState)
            } finally { serial.unlock() }
        }
    }

    private fun appInventory(): List<StorageSettingsRow> {
        val meter = StorageUsageMeter()
        val info = context.applicationInfo
        val installed = (listOfNotNull(info.sourceDir) + info.splitSourceDirs.orEmpty().toList())
            .map { meter.measure(File(it)) } + meter.measure(File(info.nativeLibraryDir))
        fun total(values: List<StorageUsageMeter.Usage>) = StorageUsageMeter.Usage(
            logicalBytes = if (values.all { it.logicalBytes != null }) values.sumOf { it.logicalBytes!! } else null,
            allocatedBytes = if (values.all { it.allocatedBytes != null }) values.sumOf { it.allocatedBytes!! } else null,
            complete = values.all { it.complete }, files = values.sumOf { it.files },
            sharedFiles = values.sumOf { it.sharedFiles }, reason = values.firstNotNullOfOrNull { it.reason },
            retainedSpecialEntries = values.sumOf { it.retainedSpecialEntries },
        )
        return listOf(
            StorageSettingsRow("appInstalled", total(installed)),
            StorageSettingsRow("appData", meter.measure(context.dataDir,
                setOf(context.cacheDir.name, context.codeCacheDir.name))),
            StorageSettingsRow("appCache", total(listOf(meter.measure(context.cacheDir), meter.measure(context.codeCacheDir)))),
        )
    }

    private fun result(response: JSONObject): JSONObject {
        check(response.getBoolean("ok"))
        return response.getJSONObject("result")
    }

    private suspend fun complete(client: RuntimeConnection, reply: JSONObject): JSONObject {
        var value = result(reply)
        val deadline = SystemClock.elapsedRealtime() + 30_000
        val requestID = if (value.optString("state") in setOf("queued", "running")) value.getString("requestID") else null
        while (value.optString("state") in setOf("queued", "running")) {
            check(SystemClock.elapsedRealtime() < deadline) { "Storage receipt pending" }
            check(value.getString("requestID") == requestID)
            delay(150)
            value = result(client.exchange("request.status", JSONObject().put("requestID", requestID)))
        }
        check(value.optString("state") == "completed")
        if (requestID != null) check(value.getString("requestID") == requestID)
        return value.getJSONObject("result")
    }

    private fun decodeRows(inventory: JSONObject): List<StorageSettingsRow> {
        check(inventory.getString("status") == "measured")
        val rows = inventory.getJSONArray("rows")
        val allowed = setOf("runtimeBase", "runtimeEnvironments", "runtimeWorkspaces", "runtimeInstaller", "runtimeOther", "runtimeCache")
        check(rows.length() == allowed.size)
        val seen = HashSet<String>()
        return (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            val id = row.getString("id")
            check(id in allowed && seen.add(id))
            fun bytes(key: String): Long? = if (row.isNull(key)) null else row.getLong(key).also { check(it >= 0) }
            StorageSettingsRow(id, StorageUsageMeter.Usage(bytes("logicalBytes"), bytes("allocatedBytes"),
                row.getBoolean("complete"), row.getInt("files").also { check(it >= 0) },
                row.getInt("sharedFiles").also { check(it >= 0) },
                if (row.isNull("reason")) null else row.getString("reason"),
                row.getInt("retainedSpecialEntries").also { check(it >= 0) }))
        }
    }
}
