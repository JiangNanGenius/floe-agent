// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.design.*

/**
 * Explicit LAN discovery page. mDNS types are chosen by the user (bounded
 * presets); the optional TCP phase needs an explicitly typed RFC1918 subnet
 * and ports. Nothing runs on entry, and the only transport is the shared
 * PhoneNetworkService command.
 */
@Composable
internal fun LanDiscoveryDetail(
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
    var selected by rememberSaveable { mutableStateOf(LanServicePresets.defaultSelection) }
    var discoverySeconds by rememberSaveable { mutableStateOf("4") }
    var includeAttributes by rememberSaveable { mutableStateOf(false) }
    var subnet by rememberSaveable { mutableStateOf("") }
    var portsText by rememberSaveable { mutableStateOf("") }
    var connectTimeout by rememberSaveable { mutableStateOf("500") }
    var concurrency by rememberSaveable { mutableStateOf("16") }
    var errors by remember { mutableStateOf(emptyList<LanValidationError>()) }

    val selectedTypes = remember(selected) {
        selected.split(',').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
    }
    val submit: () -> Unit = {
        val parsed = LanDiscoveryPolicy.parse(
            LanDiscoveryFormValues(
                serviceTypes = selectedTypes,
                discoverySeconds = discoverySeconds,
                includeAttributes = includeAttributes,
                subnetCidr = subnet,
                ports = portsText,
                tcpConnectTimeoutMs = connectTimeout,
                tcpConcurrency = concurrency,
            ),
        )
        errors = parsed.errors
        parsed.input?.let { onExecute(NetworkExecuteCommand.LanDiscovery(it)) }
    }

    LazyColumn(
        modifier.fillMaxHeight(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(stringResource(R.string.network_lan), style = Floe.typography.section)
                FloeText(
                    stringResource(R.string.network_phone_source),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeText(stringResource(R.string.network_lan_intro), style = Floe.typography.body)
            }
        }
        if (Build.VERSION.SDK_INT < 33) {
            item { FloeText(stringResource(R.string.network_lan_legacy), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                FloeText(stringResource(R.string.network_lan_services), style = Floe.typography.bodyEmphasized)
                FloeText(stringResource(R.string.network_lan_services_hint), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        }
        items(LanServicePresets.all) { type ->
            val checked = type in selectedTypes
            FloeCheckboxRow(
                label = serviceTypeLabel(type),
                checked = checked,
                onCheckedChange = { next ->
                    if (!busy) {
                        val updated = if (next) selectedTypes + type else selectedTypes - type
                        selected = LanServicePresets.all.filter { it in updated }.joinToString(",")
                        errors = emptyList()
                    }
                },
            )
        }
        item {
            FloeCheckboxRow(
                label = stringResource(R.string.network_lan_include_attributes),
                checked = includeAttributes,
                onCheckedChange = { if (!busy) includeAttributes = it },
            )
        }
        item {
            FloePlainFormField(
                label = stringResource(R.string.network_lan_discovery_seconds),
                value = discoverySeconds,
                onValueChange = { discoverySeconds = it.take(2); errors = emptyList() },
                enabled = !busy,
                isError = errors.contains(LanValidationError.DISCOVERY_SECONDS),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                FloePlainFormField(
                    label = stringResource(R.string.network_lan_subnet),
                    value = subnet,
                    onValueChange = { subnet = it.take(32); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.any {
                        it == LanValidationError.SUBNET_FORMAT ||
                            it == LanValidationError.SUBNET_PRIVATE ||
                            it == LanValidationError.SUBNET_PREFIX ||
                            it == LanValidationError.SUBNET_HOST_BITS
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
                FloeText(stringResource(R.string.network_lan_subnet_hint), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                FloePlainFormField(
                    label = stringResource(R.string.network_lan_ports),
                    value = portsText,
                    onValueChange = { portsText = it.take(64); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.any {
                        it == LanValidationError.PORTS_FORMAT ||
                            it == LanValidationError.PORTS_LIMIT ||
                            it == LanValidationError.ATTEMPT_BUDGET
                    },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                )
                FloeText(stringResource(R.string.network_lan_ports_hint), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FloePlainFormField(
                    label = stringResource(R.string.network_lan_connect_timeout),
                    value = connectTimeout,
                    onValueChange = { connectTimeout = it.take(4); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.contains(LanValidationError.CONNECT_TIMEOUT),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                FloePlainFormField(
                    label = stringResource(R.string.network_lan_concurrency),
                    value = concurrency,
                    onValueChange = { concurrency = it.take(2); errors = emptyList() },
                    enabled = !busy,
                    isError = errors.contains(LanValidationError.CONCURRENCY),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
            }
        }
        item { FloeText(stringResource(R.string.network_lan_limits), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        if (errors.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    errors.forEach { error ->
                        FloeText(lanErrorText(error), color = Floe.colors.destructive, style = Floe.typography.metadata)
                    }
                }
            }
        }
        item { RunStopRow(busy, isRunning, stopping, result == null, submit, onStop) }
        if (isRunning) {
            item { RunningElapsed(isRunning, stopping, stringResource(R.string.network_lan_running)) }
        }
        if (result == null) {
            item { FloeText(stringResource(R.string.network_no_data), style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
        } else {
            item { ObservationHeader(result) }
            if (result.status == "permissionRequired") item { PermissionSection(result, busy, onPermission) }
            val lan = result.lan
            if (lan == null) {
                val primary = when {
                    result.primaryFacts.isNotEmpty() -> result.primaryFacts
                    result.connectionFacts.isEmpty() && result.detailFacts.isEmpty() -> result.facts
                    else -> emptyList()
                }
                if (primary.isNotEmpty()) item {
                    PrimaryFactsSection(stringResource(R.string.network_primary_result), primary)
                }
            } else {
                lan.mdns?.let { mdns ->
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeText(stringResource(R.string.network_lan_services), style = Floe.typography.bodyEmphasized)
                            FloeText(
                                stringResource(
                                    R.string.network_lan_counts,
                                    mdns.serviceCount,
                                    mdns.unresolvedCount,
                                    mdns.lostCount,
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                            if (mdns.scope == "unsupportedLegacyApi") {
                                FloeText(stringResource(R.string.network_lan_scope_unsupported), style = Floe.typography.body)
                            } else if (mdns.scope == "nsdUnavailable") {
                                FloeText(stringResource(R.string.network_lan_scope_unavailable), style = Floe.typography.body)
                            }
                            if (mdns.noReplies) {
                                FloeText(stringResource(R.string.network_lan_no_replies), style = Floe.typography.body)
                            } else if (mdns.services.isEmpty() && mdns.scope == "capturedNetwork") {
                                FloeText(stringResource(R.string.network_lan_no_services), style = Floe.typography.body)
                            }
                            if (mdns.filteredForeignNetwork > 0) {
                                FloeText(
                                    stringResource(R.string.network_lan_filtered, mdns.filteredForeignNetwork),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                            if (mdns.truncated) {
                                FloeText(stringResource(R.string.network_lan_truncated), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                            }
                        }
                    }
                    items(mdns.services) { service -> LanServiceRow(service) }
                }
                lan.tcp?.let { tcp ->
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            FloeText(stringResource(R.string.network_lan_tcp), style = Floe.typography.bodyEmphasized)
                            FloeText(
                                stringResource(
                                    R.string.network_lan_tcp_summary,
                                    tcp.hostCount,
                                    tcp.completedAttempts,
                                    tcp.plannedAttempts,
                                ),
                                style = Floe.typography.metadata,
                                color = Floe.colors.secondaryLabel,
                            )
                            if (tcp.excludedSelfAddresses.isNotEmpty()) {
                                FloeText(
                                    stringResource(R.string.network_lan_excluded_self, tcp.excludedSelfAddresses.joinToString(", ")),
                                    style = Floe.typography.metadata,
                                    color = Floe.colors.secondaryLabel,
                                )
                            }
                        }
                    }
                    if (tcp.openPorts.isEmpty()) {
                        item {
                            FloeText(
                                stringResource(
                                    if (tcp.stoppedReason == "completed" && !tcp.truncated) {
                                        R.string.network_lan_no_open_ports
                                    } else {
                                        R.string.network_lan_no_open_ports_partial
                                    },
                                ),
                                style = Floe.typography.body,
                            )
                        }
                    } else {
                        item { FloeText(stringResource(R.string.network_lan_open_ports), style = Floe.typography.bodyEmphasized) }
                        items(tcp.openPorts) { open -> LanOpenPortRow(open) }
                    }
                    when {
                        tcp.cancelled -> item { FloeText(stringResource(R.string.network_lan_cancelled), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                        tcp.stoppedReason == "timeBudget" -> item { FloeText(stringResource(R.string.network_lan_budget_stopped), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                        tcp.stoppedReason == "attemptLimit" -> item { FloeText(stringResource(R.string.network_lan_attempt_stopped), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                    }
                }
                if (lan.networkChanged) {
                    item { FloeText(stringResource(R.string.network_lan_network_changed), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
                }
            }
            item { ObservationLimitations(result) }
            item { ObservationDetailsAction(onDetails) }
        }
    }
}

@Composable
private fun LanServiceRow(service: LanServiceUi) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FloeDivider()
        FloeText(
            service.serviceName.ifBlank { service.serviceType },
            style = Floe.typography.bodyEmphasized,
        )
        FloeText(service.serviceType, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        val state = when {
            service.lost -> stringResource(R.string.network_lan_lost)
            service.resolved -> stringResource(R.string.network_lan_resolved)
            else -> stringResource(R.string.network_lan_unresolved)
        }
        val endpoint = service.port?.let { port ->
            if (service.resolved) service.addresses.joinToString(", ") + ":" + port else null
        }
        FloeText(listOfNotNull(state, endpoint).joinToString(" · "), style = Floe.typography.body)
        service.hostname?.takeIf { it.isNotBlank() }?.let {
            FloeText(it, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

@Composable
private fun LanOpenPortRow(open: LanOpenPortUi) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        FloeDivider()
        FloeText(
            stringResource(R.string.network_lan_open_port_line, open.address, open.port, open.connectTimeMs),
            style = Floe.typography.body,
        )
    }
}

@Composable
private fun serviceTypeLabel(type: String): String {
    val label = stringResource(
        when (type) {
            "_http._tcp" -> R.string.network_lan_type_http
            "_https._tcp" -> R.string.network_lan_type_https
            "_ipp._tcp" -> R.string.network_lan_type_ipp
            "_ipps._tcp" -> R.string.network_lan_type_ipps
            "_printer._tcp" -> R.string.network_lan_type_printer
            "_ssh._tcp" -> R.string.network_lan_type_ssh
            "_smb._tcp" -> R.string.network_lan_type_smb
            "_airplay._tcp" -> R.string.network_lan_type_airplay
            "_raop._tcp" -> R.string.network_lan_type_raop
            "_googlecast._tcp" -> R.string.network_lan_type_googlecast
            else -> R.string.network_lan_type_other
        },
    )
    return "$label · $type"
}

@Composable
private fun lanErrorText(error: LanValidationError): String = stringResource(
    when (error) {
        LanValidationError.NO_SELECTION -> R.string.network_lan_error_selection
        LanValidationError.SERVICE_LIMIT -> R.string.network_lan_error_service_limit
        LanValidationError.SERVICE_FORMAT -> R.string.network_lan_error_service_format
        LanValidationError.DISCOVERY_SECONDS -> R.string.network_lan_error_duration
        LanValidationError.SUBNET_FORMAT -> R.string.network_lan_error_subnet
        LanValidationError.SUBNET_PRIVATE -> R.string.network_lan_error_subnet_private
        LanValidationError.SUBNET_PREFIX -> R.string.network_lan_error_subnet_prefix
        LanValidationError.SUBNET_HOST_BITS -> R.string.network_lan_error_subnet_host_bits
        LanValidationError.PORTS_FORMAT -> R.string.network_lan_error_ports
        LanValidationError.PORTS_LIMIT -> R.string.network_lan_error_ports_limit
        LanValidationError.ATTEMPT_BUDGET -> R.string.network_lan_error_attempts
        LanValidationError.CONNECT_TIMEOUT -> R.string.network_lan_error_connect_timeout
        LanValidationError.CONCURRENCY -> R.string.network_lan_error_concurrency
    },
)
