// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import android.content.Context
import android.net.Uri
import com.floe.android.ExportOutcome
import com.floe.android.MonitorExportFormat
import com.floe.android.writeMonitorExport
import com.floe.android.core.networkmonitor.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

internal data class DiagnosticReportState(
    val operationID: String? = null,
    val files: NetworkMonitorReportFiles? = null,
    val detailed: Boolean = false,
    val creating: Boolean = false,
    val exporting: Boolean = false,
    val failed: Boolean = false,
    val exportedBytes: Long? = null,
    val cancelled: Boolean = false,
    val incomplete: Boolean = false,
) { val busy: Boolean get() = creating || exporting }

/** App-owned immutable report/export work; no Activity, view, or native-root lifetime. */
internal class NetworkDiagnosticReportController(
    context: Context,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val app = context.applicationContext
    private val lock = Any()
    private val mutable = MutableStateFlow(DiagnosticReportState())
    val state: StateFlow<DiagnosticReportState> = mutable
    private var exportJob: Job? = null

    fun create(operationID: String, raw: String, detailed: Boolean): Boolean = synchronized(lock) {
        if (mutable.value.busy || raw.toByteArray(Charsets.UTF_8).size > NetworkMonitorLimits.MAX_RAW_RESULT_BYTES) return false
        mutable.value = DiagnosticReportState(operationID = operationID, detailed = detailed, creating = true)
        val job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            val files = try {
                require(JSONObject(raw).getString("operationID") == operationID)
                val packageInfo = app.packageManager.getPackageInfo(app.packageName, 0)
                val document = NetworkMonitorReportRenderer.renderDiagnostic(raw, detailed,
                    NetworkMonitorDeviceMetadata("Android ${android.os.Build.VERSION.RELEASE}", packageInfo.versionName ?: "unknown"))
                NetworkMonitorReportStore(File(app.filesDir, "network-diagnostic-reports"))
                    .write(UUID.randomUUID().toString(), document)
            } catch (cancelled: CancellationException) {
                synchronized(lock) { mutable.value = mutable.value.copy(creating = false, failed = true) }
                throw cancelled
            } catch (_: Exception) { null }
            synchronized(lock) {
                mutable.value = mutable.value.copy(files = files, creating = false, failed = files == null)
            }
        }
        job.invokeOnCompletion { cause ->
            if (cause != null) synchronized(lock) {
                if (mutable.value.operationID == operationID && mutable.value.creating)
                    mutable.value = mutable.value.copy(creating = false, failed = true)
            }
        }
        job.start()
        true
    }

    fun export(operationID: String, reportID: String, uri: Uri, format: MonitorExportFormat): Boolean = synchronized(lock) {
        val current = mutable.value
        val files = current.files ?: return false
        if (current.busy || current.operationID != operationID || files.reportId != reportID || uri.scheme != "content") return false
        mutable.value = current.copy(exporting = true, failed = false, exportedBytes = null, cancelled = false, incomplete = false)
        val job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
            val outcome = writeMonitorExport(app, uri,
                if (format == MonitorExportFormat.JSON) files.jsonFile else files.markdownFile, format)
            synchronized(lock) {
                // New creation is refused while exporting; retain the exact published report identity.
                mutable.value = mutable.value.copy(exporting = false,
                    failed = outcome == ExportOutcome.Failed || outcome == ExportOutcome.Incomplete,
                    exportedBytes = (outcome as? ExportOutcome.Exported)?.bytes,
                    cancelled = outcome == ExportOutcome.Cancelled, incomplete = outcome == ExportOutcome.Incomplete)
                exportJob = null
            }
        }
        exportJob = job
        job.invokeOnCompletion { cause ->
            if (cause != null) synchronized(lock) {
                if (mutable.value.operationID == operationID && mutable.value.exporting) {
                    mutable.value = mutable.value.copy(exporting = false, cancelled = true)
                    exportJob = null
                }
            }
        }
        job.start()
        true
    }

    fun cancelExport(operationID: String) = synchronized(lock) {
        if (mutable.value.operationID == operationID) exportJob?.cancel()
    }
}
