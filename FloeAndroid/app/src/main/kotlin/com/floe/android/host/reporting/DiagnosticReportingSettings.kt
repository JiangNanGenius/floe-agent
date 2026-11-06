// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.design.*
import com.floe.android.host.entryflow.C07DiagnosticsExport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal fun DiagnosticReportingSettings() {
    val context = LocalContext.current
    val app = context.applicationContext as? FloeApplication ?: return
    val reporter = app.diagnosticReporter
    val state by reporter.state.collectAsState()
    val scope = rememberCoroutineScope()
    var consent by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf("") }
    var images by remember { mutableStateOf<List<Uri>>(emptyList()) }
    var anyNetwork by remember { mutableStateOf(false) }
    var diagnostics by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var submittedID by remember { mutableStateOf<String?>(null) }
    var tooManyImages by remember { mutableStateOf(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) {
        if (it.size > 4) tooManyImages = true else images = it
    }
    FloeSettingsSectionCard(title = stringResource(R.string.reporting_title)) {
        FloeSectionRow(title = { FloeText(stringResource(R.string.reporting_automatic)) }, trailing = {
            FloeInlineSwitch(state.automatic,
                { if (it) consent = true else scope.launch(Dispatchers.IO) { reporter.setAutomatic(false) } },
                description = stringResource(R.string.reporting_automatic))
        })
        FloeSectionRow(title = {
            FloeText(stringResource(R.string.reporting_privacy), style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel)
        })
        FloePlainFormField(label = stringResource(R.string.reporting_problem), value = problem,
            onValueChange = { problem = it.take(8_000) })
        FloeSectionRow(title = { FloeText(stringResource(R.string.reporting_include_diagnostics)) }, trailing = {
            FloeInlineSwitch(diagnostics, { diagnostics = it },
                description = stringResource(R.string.reporting_include_diagnostics))
        })
        FloeActionRow(label = stringResource(R.string.reporting_select_images, images.size),
            enabled = !sending, onClick = { picker.launch(arrayOf("image/jpeg", "image/png")) })
        if (images.isNotEmpty()) {
            FloeActionRow(label = stringResource(R.string.reporting_clear_images), enabled = !sending,
                onClick = { images = emptyList() })
            FloeSectionRow(title = { FloeText(stringResource(R.string.reporting_any_network)) }, trailing = {
                FloeInlineSwitch(anyNetwork, { anyNetwork = it },
                    description = stringResource(R.string.reporting_any_network))
            })
        }
        FloeActionRow(label = stringResource(if (sending) R.string.reporting_preparing else R.string.reporting_submit),
            enabled = !sending && (problem.isNotBlank() || images.isNotEmpty()), onClick = {
                sending = true; failure = null
                val currentProblem = problem
                val currentImages = images
                val includeDiagnostics = diagnostics
                val network = anyNetwork
                scope.launch {
                    try {
                        val text = withContext(Dispatchers.IO) {
                            if (includeDiagnostics) C07DiagnosticsExport.build(context, app.runtimeHost,
                                currentProblem, includeDiagnostics = true) else currentProblem
                        }
                        submittedID = reporter.submitManual(text, currentImages, network)
                        problem = ""; images = emptyList()
                    } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                    catch (error: Exception) {
                        failure = when (error.message) {
                            "image_too_large" -> "image_too_large"
                            "image_invalid", "image_unreadable" -> "image_invalid"
                            "image_memory" -> "image_memory"
                            else -> "prepare_failed"
                        }
                    }
                    finally { sending = false }
                }
            })
        if (images.isNotEmpty()) FloeSectionRow(title = {
            FloeText(stringResource(R.string.reporting_compression), style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel)
        })
        for (row in state.reports.asReversed().take(20)) {
            FloeSectionRow(title = {
                Column {
                    FloeText(stringResource(if (row.kind == "manual") R.string.reporting_manual else R.string.reporting_fault))
                    FloeText(when {
                        row.uploading -> stringResource(R.string.reporting_upload_progress,
                            row.transferred * 100 / row.transferTotal.coerceAtLeast(1))
                        row.state == "sent" -> stringResource(R.string.reporting_receipt, row.reportID.orEmpty())
                        row.state == "failed" -> stringResource(R.string.reporting_rejected)
                        else -> stringResource(R.string.reporting_queued)
                    }, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    if (row.state != "sent") row.errorCode?.let {
                        FloeText(reportErrorMessage(it), style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel)
                    }
                    Spacer(Modifier.height(4.dp))
                }
            })
            if (row.state == "failed") FloeActionRow(label = stringResource(R.string.retry),
                onClick = { scope.launch(Dispatchers.IO) { reporter.retry(row.id) } })
            FloeActionRow(label = stringResource(R.string.reporting_remove),
                onClick = { scope.launch(Dispatchers.IO) { reporter.remove(row.id) } })
        }
    }
    if (consent) FloeConfirmDialog(title = stringResource(R.string.reporting_automatic),
        message = stringResource(R.string.reporting_privacy),
        confirmLabel = stringResource(R.string.reporting_agree), dismissLabel = stringResource(R.string.cancel),
        onConfirm = { consent = false; scope.launch(Dispatchers.IO) { reporter.setAutomatic(true) } },
        onDismiss = { consent = false })
    if (tooManyImages) FloeConfirmDialog(title = stringResource(R.string.reporting_title),
        message = stringResource(R.string.reporting_image_count), confirmLabel = stringResource(R.string.done),
        dismissLabel = stringResource(R.string.cancel), onConfirm = { tooManyImages = false },
        onDismiss = { tooManyImages = false })
    failure?.let { code ->
        FloeConfirmDialog(title = stringResource(R.string.reporting_title), message = reportErrorMessage(code),
            confirmLabel = stringResource(R.string.done), dismissLabel = stringResource(R.string.cancel),
            onConfirm = { failure = null }, onDismiss = { failure = null })
    }
    submittedID?.let { id ->
        val row = state.reports.firstOrNull { it.id == id }
        val message = when {
            row?.uploading == true -> stringResource(R.string.reporting_upload_progress,
                row.transferred * 100 / row.transferTotal.coerceAtLeast(1))
            row?.state == "sent" -> stringResource(R.string.reporting_receipt, row.reportID.orEmpty())
            row?.state == "failed" -> reportErrorMessage(row.errorCode.orEmpty())
            else -> row?.errorCode?.let { reportErrorMessage(it) }
                ?: stringResource(R.string.reporting_saved_for_upload)
        }
        FloeConfirmDialog(title = stringResource(R.string.reporting_title), message = message,
            confirmLabel = stringResource(R.string.done),
            dismissLabel = stringResource(if (row?.state == "queued") R.string.reporting_stop_upload else R.string.cancel),
            onConfirm = { submittedID = null }, onDismiss = {
                if (row?.state == "queued") scope.launch(Dispatchers.IO) { reporter.cancel(id) }
                submittedID = null
            })
    }
}

@Composable
private fun reportErrorMessage(code: String): String = stringResource(when {
    code == "upload_cancelled" -> R.string.reporting_upload_cancelled
    code == "client_update_required" -> R.string.reporting_update_required
    code == "waiting_wifi" -> R.string.reporting_waiting_wifi
    code == "image_too_large" -> R.string.reporting_image_too_large
    code == "image_invalid" -> R.string.reporting_image_invalid
    code == "image_memory" -> R.string.reporting_image_memory
    code == "network_dns" -> R.string.reporting_network_dns
    code == "network_timeout" -> R.string.reporting_network_timeout
    code == "network_tls" -> R.string.reporting_network_tls
    code == "http_429" -> R.string.reporting_busy
    code.startsWith("http_5") -> R.string.reporting_server_unavailable
    code == "http_413" || code == "http_422" -> R.string.reporting_attachment_rejected
    code == "invalid_receipt" -> R.string.reporting_receipt_unconfirmed
    code == "network_connection" -> R.string.reporting_network_connection
    code.startsWith("http_") -> R.string.reporting_rejected
    else -> R.string.reporting_prepare_failed
})
