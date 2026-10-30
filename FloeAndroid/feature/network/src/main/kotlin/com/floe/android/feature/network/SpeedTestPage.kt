// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.design.*

/**
 * Explicit, budgeted speed page. There is no default endpoint and no implicit
 * upload: the user selects a direction and supplies every HTTPS endpoint.
 * Rates are rendered only when the service says the measurement interval and
 * byte count support one.
 */
@Composable
internal fun SpeedTestDetail(
    result: NetworkObservationUi?,
    busy: Boolean,
    isRunning: Boolean,
    stopping: Boolean,
    onExecute: (NetworkExecuteCommand) -> Unit,
    onStop: () -> Unit,
    onPermission: (List<String>) -> Unit,
    onDetails: () -> Unit,
    modifier: Modifier,
) {
    var directionIndex by rememberSaveable { mutableIntStateOf(0) }
    var downloadUrl by rememberSaveable { mutableStateOf("") }
    var uploadUrl by rememberSaveable { mutableStateOf("") }
    var maxMiB by rememberSaveable { mutableStateOf("8") }
    var durationSeconds by rememberSaveable { mutableStateOf("10") }
    var allowMetered by rememberSaveable { mutableStateOf(false) }
    var errors by remember { mutableStateOf(emptyList<SpeedTestValidationError>()) }
    val direction = SpeedTestDirection.entries[directionIndex]
    val options = listOf(
        stringResource(R.string.network_speed_download),
        stringResource(R.string.network_speed_upload),
        stringResource(R.string.network_speed_both),
    )
    val submit: () -> Unit = {
        val parsed = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                direction = direction,
                downloadUrl = downloadUrl,
                uploadUrl = uploadUrl,
                maxMiB = maxMiB,
                durationSeconds = durationSeconds,
                allowMetered = allowMetered,
            ),
        )
        errors = parsed.errors
        parsed.input?.let { onExecute(NetworkExecuteCommand.SpeedTest(it)) }
    }
    val parsedSeconds = durationSeconds.trim().toIntOrNull()
    val bothDurationTooLong = direction == SpeedTestDirection.BOTH &&
        parsedSeconds != null && parsedSeconds > 14
    val previewTimeout = parsedSeconds
        ?.takeIf { it in 1..15 && !bothDurationTooLong }
        ?.let { it * 1_000 * direction.count + SpeedTestPolicy.CONNECTION_MARGIN_MS }
    val shownErrors = buildList {
        if (bothDurationTooLong && SpeedTestValidationError.DURATION_BOTH !in errors) {
            add(SpeedTestValidationError.DURATION_BOTH)
        }
        addAll(errors)
    }

    LazyColumn(
        modifier.fillMaxHeight(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(stringResource(R.string.network_speed), style = Floe.typography.section)
                FloeText(
                    stringResource(R.string.network_phone_source),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(stringResource(R.string.network_speed_intro), style = Floe.typography.body)
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(stringResource(R.string.network_speed_direction), style = Floe.typography.bodyEmphasized)
                FloeSegmented(
                    options = options,
                    selectedIndex = directionIndex,
                    onSelect = { index ->
                        if (!busy) {
                            directionIndex = index
                            errors = emptyList()
                        }
                    },
                )
            }
        }
        if (direction.includesDownload) {
            item {
                FloePlainFormField(
                    label = stringResource(R.string.network_speed_download_url),
                    value = downloadUrl,
                    onValueChange = { downloadUrl = it.take(4_096); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.contains(SpeedTestValidationError.DOWNLOAD_URL_REQUIRED) ||
                        errors.contains(SpeedTestValidationError.URL_INVALID),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
            }
        }
        if (direction.includesUpload) {
            item {
                FloePlainFormField(
                    label = stringResource(R.string.network_speed_upload_url),
                    value = uploadUrl,
                    onValueChange = { uploadUrl = it.take(4_096); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.contains(SpeedTestValidationError.UPLOAD_URL_REQUIRED) ||
                        errors.contains(SpeedTestValidationError.URL_INVALID),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
            }
            item {
                FloeText(
                    stringResource(R.string.network_speed_upload_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        item {
            FloeText(stringResource(R.string.network_speed_url_hint), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FloePlainFormField(
                    label = stringResource(R.string.network_speed_data_cap),
                    value = maxMiB,
                    onValueChange = { maxMiB = it.take(2); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.contains(SpeedTestValidationError.BYTE_CAP),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                FloePlainFormField(
                    label = stringResource(R.string.network_speed_time_budget),
                    value = durationSeconds,
                    onValueChange = { durationSeconds = it.take(2); errors = emptyList() },
                    enabled = !busy,
                    isError = bothDurationTooLong ||
                        errors.contains(SpeedTestValidationError.DURATION) ||
                        errors.contains(SpeedTestValidationError.DURATION_BOTH),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
            }
        }
        item { FloeText(stringResource(R.string.network_speed_budget_hint), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        item {
            FloeCheckboxRow(
                label = stringResource(R.string.network_speed_allow_metered),
                checked = allowMetered,
                onCheckedChange = { if (!busy) allowMetered = it },
            )
        }
        item { FloeText(stringResource(R.string.network_speed_metered_note), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        item { FloeText(stringResource(R.string.network_speed_single_note), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        previewTimeout?.let { timeout ->
            item {
                FloeText(
                    stringResource(R.string.network_speed_timeout, NetworkMeasureFormat.duration(timeout.toLong())),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        if (shownErrors.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    shownErrors.forEach { error ->
                        FloeText(speedErrorText(error), color = Floe.colors.destructive, style = Floe.typography.metadata)
                    }
                }
            }
        }
        item { RunStopRow(busy, isRunning, stopping, result == null, submit, onStop) }
        if (isRunning) {
            item { RunningElapsed(isRunning, stopping, stringResource(R.string.network_speed_running)) }
        }
        if (result == null) {
            item { FloeText(stringResource(R.string.network_no_data), style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
        } else {
            item { ObservationHeader(result) }
            if (result.status == "permissionRequired") item { PermissionSection(result, busy, onPermission) }
            val speed = result.speed
            if (speed == null) {
                val primary = when {
                    result.primaryFacts.isNotEmpty() -> result.primaryFacts
                    result.connectionFacts.isEmpty() && result.detailFacts.isEmpty() -> result.facts
                    else -> emptyList()
                }
                if (primary.isNotEmpty()) item {
                    PrimaryFactsSection(stringResource(R.string.network_primary_result), primary)
                }
            } else {
                item { SpeedBudget(speed) }
                if (speed.metered == true) {
                    item {
                        FloeText(
                            stringResource(
                                if (speed.allowMetered) R.string.network_speed_metered_allowed else R.string.network_speed_metered,
                            ),
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                    }
                }
                items(speed.transfers) { transfer -> SpeedTransferBlock(transfer) }
                if (speed.sampleAdequate == false) {
                    item { FloeText(stringResource(R.string.network_speed_sample_inadequate), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                }
                if (speed.proxyConfigured) {
                    item { FloeText(stringResource(R.string.network_speed_proxy), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                }
                if (speed.networkChanged) {
                    item { FloeText(stringResource(R.string.network_speed_network_changed), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                }
            }
            item { ObservationLimitations(result) }
            item { ObservationDetailsAction(onDetails) }
        }
    }
}

@Composable
private fun SpeedBudget(speed: SpeedTestUi) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val cap = speed.maxBytesPerDirection
        val duration = speed.durationBudgetMs
        if (cap != null && duration != null) {
            FloeText(
                stringResource(
                    R.string.network_speed_budget_line,
                    NetworkMeasureFormat.bytes(cap),
                    NetworkMeasureFormat.duration(duration),
                ),
                style = Floe.typography.body,
            )
        }
        speed.timeoutMs?.let { timeout ->
            FloeText(
                stringResource(R.string.network_speed_timeout, NetworkMeasureFormat.duration(timeout)),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
private fun SpeedTransferBlock(transfer: SpeedTransferUi) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FloeDivider()
        FloeText(
            stringResource(
                if (transfer.direction == "upload") R.string.network_speed_result_upload else R.string.network_speed_result_download,
            ),
            style = Floe.typography.section,
        )
        SelectionContainer {
            FloeText(transfer.endpoint, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        FactLine(stringResource(R.string.network_speed_status), statusTitle(transfer.status))
        transfer.httpStatus?.let { FactLine(stringResource(R.string.network_speed_http_status), it.toString()) }
        transfer.measuredBytes?.let {
            FactLine(stringResource(R.string.network_speed_transferred), NetworkMeasureFormat.bytes(it))
        }
        transfer.measurementElapsedMs?.let {
            FactLine(stringResource(R.string.network_speed_measurement_elapsed), NetworkMeasureFormat.duration(it))
        }
        transfer.totalElapsedMs?.let {
            FactLine(stringResource(R.string.network_speed_total_elapsed), NetworkMeasureFormat.duration(it))
        }
        val rate = if (transfer.rateAvailable && transfer.bitsPerSecond != null) {
            NetworkMeasureFormat.bitsPerSecond(transfer.bitsPerSecond)
        } else {
            rateUnavailableText(transfer.rateOmittedReason)
        }
        FactLine(stringResource(R.string.network_speed_rate), rate)
        transfer.completionReason?.let {
            FactLine(stringResource(R.string.network_speed_completion), speedCompletionText(it))
        }
        if (transfer.tlsProtocol != null) {
            FactLine(
                stringResource(R.string.network_speed_tls),
                listOfNotNull(transfer.tlsProtocol, transfer.cipherSuite).joinToString(" · "),
            )
        }
        if (transfer.direction == "upload") {
            FloeText(stringResource(R.string.network_speed_upload_note), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

@Composable
private fun rateUnavailableText(reason: String?): String {
    val base = stringResource(R.string.network_speed_rate_unavailable)
    val detail = when (reason) {
        "measurementIntervalTooShort" -> stringResource(R.string.network_speed_rate_too_short)
        "noMeasurementInterval" -> stringResource(R.string.network_speed_rate_no_interval)
        "noMeasuredBytes" -> stringResource(R.string.network_speed_rate_no_bytes)
        "rateNotFinite" -> stringResource(R.string.network_speed_rate_not_finite)
        else -> null
    }
    return if (detail != null) "$base · $detail" else base
}

@Composable
private fun speedCompletionText(reason: String): String = stringResource(
    when (reason) {
        "contentComplete" -> R.string.network_speed_completion_content
        "byteBudget" -> R.string.network_speed_completion_byte_budget
        "timeBudget" -> R.string.network_speed_completion_time_budget
        "cancelled" -> R.string.network_speed_completion_cancelled
        "networkChanged" -> R.string.network_speed_completion_network_changed
        "httpStatusError" -> R.string.network_speed_completion_http
        "redirectNotFollowed" -> R.string.network_speed_completion_redirect
        "tlsFailure" -> R.string.network_speed_completion_tls
        "dnsFailure" -> R.string.network_speed_completion_dns
        "connectFailure" -> R.string.network_speed_completion_connect
        "ioFailure" -> R.string.network_speed_completion_io
        "emptyResponse" -> R.string.network_speed_completion_empty
        "inProgress" -> R.string.network_speed_completion_in_progress
        // G07.2 framing08 typed failures: ordinary UI groups malformed vs
        // truncated response; the raw completionReason code stays in Details.
        "ambiguousContentLength", "invalidContentLength", "ambiguousFraming",
        "unsupportedTransferEncoding", "invalidChunkFraming", "oversizedChunkFraming",
        "oversizedHeaders", "malformedHeaders", "invalidStatusLine",
        "tooManyInterimResponses" -> R.string.network_speed_completion_malformed
        "truncatedBody", "truncatedHeaders" -> R.string.network_speed_completion_truncated
        else -> R.string.network_speed_completion_unknown
    },
)

@Composable
private fun speedErrorText(error: SpeedTestValidationError): String = stringResource(
    when (error) {
        SpeedTestValidationError.DOWNLOAD_URL_REQUIRED -> R.string.network_speed_validation_download
        SpeedTestValidationError.UPLOAD_URL_REQUIRED -> R.string.network_speed_validation_upload
        SpeedTestValidationError.URL_INVALID -> R.string.network_speed_validation_url
        SpeedTestValidationError.BYTE_CAP -> R.string.network_speed_validation_cap
        SpeedTestValidationError.DURATION -> R.string.network_speed_validation_duration
        SpeedTestValidationError.DURATION_BOTH -> R.string.network_speed_validation_both_duration
    },
)
