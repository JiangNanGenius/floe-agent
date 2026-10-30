// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.feature.network.NetworkObservationUi
import com.floe.android.feature.network.R as NetworkR
import com.floe.android.host.network.NetworkDiagnosticReportController
import com.floe.android.safgateway.*
import org.json.JSONObject

@Composable
internal fun NetworkDiagnosticReportControls(controller: NetworkDiagnosticReportController, observation: NetworkObservationUi) {
    val operationID = remember(observation.details) {
        runCatching { JSONObject(observation.details).getString("operationID") }.getOrNull()
    } ?: return
    val global by controller.state.collectAsState()
    val current = global.takeIf { it.operationID == operationID }
    var detailed by rememberSaveable(operationID) { mutableStateOf(false) }
    var pendingReport by rememberSaveable(operationID) { mutableStateOf<String?>(null) }
    var pendingFormat by rememberSaveable(operationID) { mutableStateOf<String?>(null) }
    var localFailure by remember(operationID) { mutableStateOf(false) }
    var pickerCancelled by remember(operationID) { mutableStateOf(false) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val reportID = pendingReport
        val format = pendingFormat?.let { runCatching { MonitorExportFormat.valueOf(it) }.getOrNull() }
        pendingReport = null; pendingFormat = null
        if (result.resultCode != Activity.RESULT_OK) pickerCancelled = true
        else if (reportID != null && format != null) {
            val uri = SafPickerIntents.resultUriString(result.data)?.let { Uri.parse(it) }
            val flags = SafPickerIntents.resultFlags(result.data)
            if (uri == null || flags and SafGrantFlagBits.GRANT_WRITE == 0 ||
                !controller.export(operationID, reportID, uri, format)) localFailure = true
        }
    }
    fun beginExport(format: MonitorExportFormat) {
        val report = current?.files ?: return
        if (pendingReport != null || global.busy) return
        pendingReport = report.reportId; pendingFormat = format.name
        localFailure = false; pickerCancelled = false
        try {
            launcher.launch(SafPickerIntents.from(PickRequestSpec(
                requestKey = "diagnostic-export-${report.reportId}-${format.name}",
                kind = PickKind.CREATE_DOCUMENT, mimeTypes = listOf(format.mimeType),
                suggestedName = "floe-network-diagnostic-${report.reportId.take(8)}.${format.extension}",
                initialDirectory = null)))
        } catch (_: Exception) { pendingReport = null; pendingFormat = null; localFailure = true }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeDivider()
        FloeText(stringResource(NetworkR.string.network_monitor_report), style = Floe.typography.section)
        FloeCheckboxRow(stringResource(NetworkR.string.network_monitor_report_detailed), detailed,
            onCheckedChange = { if (!global.busy && pendingReport == null) detailed = it })
        FloeText(stringResource(if (detailed) NetworkR.string.network_monitor_report_detailed_note
            else NetworkR.string.network_monitor_report_redacted_note), style = Floe.typography.metadata)
        FloeCapsuleButton(stringResource(if (current?.creating == true) NetworkR.string.network_monitor_report_creating
            else NetworkR.string.network_monitor_report_create), onClick = {
            localFailure = !controller.create(operationID, observation.details, detailed)
        }, enabled = !global.busy && pendingReport == null)
        current?.files?.let {
            FloeText(stringResource(NetworkR.string.network_monitor_report_storage), style = Floe.typography.metadata)
            FloeText(stringResource(if (current?.detailed == true) NetworkR.string.network_monitor_report_mode_detailed
                else NetworkR.string.network_monitor_report_mode_redacted), style = Floe.typography.metadata)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleButton(stringResource(NetworkR.string.network_monitor_export_json),
                    { beginExport(MonitorExportFormat.JSON) }, enabled = !global.busy && pendingReport == null, modifier = Modifier.weight(1f))
                FloeCapsuleButton(stringResource(NetworkR.string.network_monitor_export_markdown),
                    { beginExport(MonitorExportFormat.MARKDOWN) }, enabled = !global.busy && pendingReport == null, modifier = Modifier.weight(1f))
            }
        }
        if (current?.exporting == true) FloeCapsuleButton(stringResource(NetworkR.string.network_monitor_export_cancel),
            { controller.cancelExport(operationID) })
        if (current?.incomplete == true) FloeText(stringResource(NetworkR.string.network_monitor_export_incomplete), style = Floe.typography.metadata)
        if (localFailure || (current?.failed == true && current?.incomplete != true)) FloeText(stringResource(if (current?.files != null) NetworkR.string.network_monitor_export_failed else NetworkR.string.network_diagnostic_report_failed),
            style = Floe.typography.metadata, color = Floe.colors.destructive)
        if (pickerCancelled || current?.cancelled == true) FloeText(stringResource(NetworkR.string.network_monitor_export_cancelled), style = Floe.typography.metadata)
        current?.exportedBytes?.let { FloeText(stringResource(NetworkR.string.network_monitor_exported, it), style = Floe.typography.metadata) }
    }
}
