// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import kotlinx.coroutines.delay

/** Stable native shell: categories on tablets, list → detail → list on phones. */
@Composable
fun NetworkWorkbench(
    state: NetworkWorkbenchState,
    compact: Boolean,
    onExecute: (NetworkExecuteCommand) -> Unit,
    onStop: () -> Unit,
    onPermission: (List<String>) -> Unit,
    onOpenLocationSettings: () -> Unit,
    onNavigate: () -> Unit,
    showSidebarToggle: Boolean = false,
    /**
     * Optional dedicated monitoring panel. The workbench only owns its
     * selection/back behavior; the service-owned state and report controls
     * stay in the App host/UI. When absent, the eight measurement pages are
     * byte-for-byte the previous surface.
     */
    monitoringLabel: String? = null,
    monitoringContent: (@Composable (Modifier) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    var selection by rememberSaveable { mutableStateOf<String?>(null) }
    var detailsPage by rememberSaveable { mutableStateOf<String?>(null) }
    var monitoringSelected by rememberSaveable { mutableStateOf(false) }
    val monitoring = monitoringContent?.takeIf { monitoringLabel != null }
    val monitoringVisible = monitoringSelected && monitoring != null
    val page = if (monitoringVisible) {
        null
    } else {
        selection?.let { saved -> NetworkPage.entries.firstOrNull { it.name == saved } }
            ?: if (compact) null else NetworkPage.OVERVIEW
    }
    val detailVisible = page != null || monitoringVisible
    val back: () -> Unit = {
        if (compact && detailVisible) {
            selection = null
            monitoringSelected = false
        } else {
            onNavigate()
        }
    }
    BackHandler(enabled = compact && detailVisible, onBack = back)
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = when {
                compact && monitoringVisible -> monitoringLabel ?: stringResource(R.string.network_title)
                compact && page != null -> pageTitle(page)
                else -> stringResource(R.string.network_title)
            },
            // Wide layouts already have the shell/sidebar navigation; a second
            // sidebar-toggle glyph here duplicated it while expanded. The
            // actual collapsed state comes from the shell, so only that state
            // gets a real expand action (never a "Back" label on a sidebar
            // glyph). Phones keep Back on a detail and a drawer action on the
            // category list.
            navigation = when {
                compact && detailVisible -> {
                    {
                        FloeCircleButton(
                            icon = FloeIcons.ChevronBack,
                            contentDescription = stringResource(
                                if (monitoringVisible) R.string.network_monitor_back
                                else R.string.network_back,
                            ),
                            onClick = back,
                        )
                    }
                }
                compact -> {
                    {
                        FloeCircleButton(
                            icon = FloeIcons.SidebarToggle,
                            contentDescription = stringResource(R.string.network_open_navigation),
                            onClick = back,
                        )
                    }
                }
                showSidebarToggle -> {
                    {
                        FloeCircleButton(
                            icon = FloeIcons.SidebarToggle,
                            contentDescription = stringResource(R.string.network_expand_navigation),
                            onClick = onNavigate,
                        )
                    }
                }
                else -> null
            },
            showHairline = true,
        )
        Row(Modifier.weight(1f)) {
            if (!compact || !detailVisible) {
                Column(
                    Modifier.then(if (compact) Modifier.fillMaxWidth() else Modifier.width(220.dp))
                        .fillMaxHeight().background(Floe.colors.groupedSurface).verticalScroll(rememberScrollState())
                        .padding(vertical = 16.dp),
                ) {
                    NetworkPage.entries.forEach { item ->
                        FloeSidebarRow(
                            icon = when (item) {
                                NetworkPage.OVERVIEW, NetworkPage.WIFI -> FloeIcons.Antenna
                                NetworkPage.LAN -> FloeIcons.Antenna
                                NetworkPage.SPEED -> FloeIcons.Gauge
                                NetworkPage.DNS -> FloeIcons.Magnifier
                                NetworkPage.PING -> FloeIcons.Gauge
                                NetworkPage.TCP -> FloeIcons.Terminal
                                NetworkPage.HTTPS -> FloeIcons.ShieldCheck
                            },
                            label = pageTitle(item), selected = item == page,
                            onClick = {
                                selection = item.name
                                monitoringSelected = false
                            },
                            modifier = Modifier.padding(horizontal = 10.dp),
                        )
                    }
                    val panel = monitoring
                    if (panel != null && monitoringLabel != null) {
                        FloeDivider(Modifier.padding(horizontal = 10.dp, vertical = 8.dp))
                        FloeSidebarRow(
                            icon = FloeIcons.Clock,
                            label = monitoringLabel,
                            selected = monitoringVisible,
                            onClick = {
                                selection = null
                                monitoringSelected = true
                            },
                            modifier = Modifier.padding(horizontal = 10.dp),
                        )
                    }
                }
            }
            if (!compact) FloeVerticalDivider()
            val panel = monitoring
            if (monitoringVisible && panel != null) {
                panel(Modifier.weight(1f))
            } else if (page != null) {
                NetworkDetail(
                    page = page, result = state.results[page], busy = state.running != null,
                    isRunning = state.running == page, stopping = state.stopping,
                    onExecute = onExecute, onStop = onStop,
                    onPermission = onPermission,
                    onOpenLocationSettings = onOpenLocationSettings, onDetails = { detailsPage = it.name },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
    val detailsResult = detailsPage?.let { name ->
        NetworkPage.entries.firstOrNull { it.name == name }?.let { state.results[it] }
    }
    FloePageSheet(
        visible = detailsResult != null, onDismiss = { detailsPage = null },
        widthFraction = if (compact) 1f else 0.78f, heightFraction = 0.85f,
        placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
    ) {
        detailsResult?.let { result ->
            NetworkDetailsSheet(result = result, onClose = { detailsPage = null })
        }
    }
}

/**
 * Explicit Details sheet. The captured-network snapshot (addresses, routes,
 * DNS servers, interface, Wi-Fi link metadata, …) lives here instead of
 * pushing the measured answer down the page. Raw NetworkObservationV1 stays
 * available for diagnostics. It contains actual fields only; no synthetic
 * rows are added for missing values.
 */
@Composable
private fun NetworkDetailsSheet(result: NetworkObservationUi, onClose: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        FloeToolbar(title = stringResource(R.string.network_details), actions = {
            FloeCircleButton(FloeIcons.Xmark, stringResource(R.string.network_close), onClose)
        }, showHairline = true)
        SelectionContainer(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
                if (result.connectionFacts.isNotEmpty()) {
                    DetailsGroup(stringResource(R.string.network_details_connection), result.connectionFacts)
                }
                if (result.detailFacts.isNotEmpty()) {
                    DetailsGroup(stringResource(R.string.network_details_other), result.detailFacts)
                }
                if (result.connectionFacts.isEmpty() && result.detailFacts.isEmpty() && result.details.isBlank()) {
                    FloeText(stringResource(R.string.network_empty_result), style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel)
                }
                if (result.details.isNotBlank()) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeDivider()
                        FloeText(stringResource(R.string.network_details_raw), style = Floe.typography.section)
                        FloeText(result.details, style = Floe.typography.evidence)
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailsGroup(title: String, facts: List<NetworkFactUi>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeText(title, style = Floe.typography.section)
        facts.forEach { fact ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                FloeText(fact.label, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeText(fact.value, style = Floe.typography.body)
            }
        }
    }
}

@Composable
private fun NetworkDetail(
    page: NetworkPage, result: NetworkObservationUi?, busy: Boolean, isRunning: Boolean,
    stopping: Boolean, onExecute: (NetworkExecuteCommand) -> Unit, onStop: () -> Unit,
    onPermission: (List<String>) -> Unit, onOpenLocationSettings: () -> Unit,
    onDetails: (NetworkPage) -> Unit, modifier: Modifier,
) {
    when (page) {
        NetworkPage.LAN -> LanDiscoveryDetail(
            result = result, busy = busy, isRunning = isRunning, stopping = stopping,
            onExecute = onExecute, onStop = onStop, onPermission = onPermission,
            onDetails = { onDetails(NetworkPage.LAN) }, modifier = modifier,
        )
        NetworkPage.SPEED -> SpeedTestDetail(
            result = result, busy = busy, isRunning = isRunning, stopping = stopping,
            onExecute = onExecute, onStop = onStop, onPermission = onPermission,
            onDetails = { onDetails(NetworkPage.SPEED) }, modifier = modifier,
        )
        else -> SimpleNetworkDetail(
            page = page, result = result, busy = busy, isRunning = isRunning,
            stopping = stopping, onExecute = onExecute, onStop = onStop,
            onPermission = onPermission, onOpenLocationSettings = onOpenLocationSettings,
            onDetails = { onDetails(page) }, modifier = modifier,
        )
    }
}

@Composable
private fun SimpleNetworkDetail(
    page: NetworkPage, result: NetworkObservationUi?, busy: Boolean, isRunning: Boolean,
    stopping: Boolean, onExecute: (NetworkExecuteCommand) -> Unit, onStop: () -> Unit,
    onPermission: (List<String>) -> Unit, onOpenLocationSettings: () -> Unit,
    onDetails: () -> Unit, modifier: Modifier,
) {
    var target by rememberSaveable(page) { mutableStateOf("") }
    var port by rememberSaveable(page) { mutableStateOf("443") }
    var error by rememberSaveable(page) { mutableStateOf(false) }
    val validPort = port.toIntOrNull()?.let { it in 1..65535 } == true
    val run: () -> Unit = {
        error = (page.needsTarget && target.isBlank()) || (page == NetworkPage.TCP && !validPort)
        if (!error) {
            onExecute(
                NetworkExecuteCommand.Simple(
                    page,
                    buildMap {
                        if (page.needsTarget) put(if (page == NetworkPage.HTTPS) "url" else "host", target.trim())
                        if (page == NetworkPage.TCP) put("port", port)
                        if (page == NetworkPage.WIFI) put("refresh", "true")
                    },
                ),
            )
        }
    }
    LazyColumn(modifier.fillMaxHeight(), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(pageTitle(page), style = Floe.typography.section)
                FloeText(stringResource(R.string.network_phone_source), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        }
        if (page.needsTarget) item {
            FloePlainFormField(
                label = stringResource(if (page == NetworkPage.HTTPS) R.string.network_url else R.string.network_host),
                value = target, onValueChange = { target = it.take(2048); error = false },
                enabled = !busy, isError = error && target.isBlank(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
        }
        if (page == NetworkPage.TCP) item {
            FloePlainFormField(
                label = stringResource(R.string.network_port), value = port,
                onValueChange = { port = it.take(5); error = false }, enabled = !busy,
                isError = error && !validPort, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        }
        if (error) item {
            FloeText(stringResource(if (page == NetworkPage.TCP && !validPort) R.string.network_invalid_port else R.string.network_invalid_target),
                color = Floe.colors.destructive, style = Floe.typography.metadata)
        }
        item { RunStopRow(busy, isRunning, stopping, result == null || page.needsTarget, run, onStop) }
        if (isRunning) item { RunningElapsed(isRunning, stopping, stringResource(R.string.network_busy)) }
        if (result == null) {
            item { FloeText(stringResource(R.string.network_no_data), style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
        } else {
            item { ObservationHeader(result) }
            if (result.status == "permissionRequired") item { PermissionSection(result, busy, onPermission) }
            val primary = when {
                result.primaryFacts.isNotEmpty() -> result.primaryFacts
                // Source-compatible fallback for callers that have not yet
                // projected the structured sections (old App controller):
                // show their actual facts rather than an empty page.
                result.connectionFacts.isEmpty() && result.detailFacts.isEmpty() -> result.facts
                else -> emptyList()
            }
            if (page == NetworkPage.WIFI) {
                val linkFacts = primary.filter { it.key?.startsWith("network.wifi.") == true }
                val scanFacts = primary.filter { it.key?.startsWith("observations.") == true }
                val unkeyed = primary.filter { it.key == null }
                if (linkFacts.isNotEmpty()) item {
                    PrimaryFactsSection(stringResource(R.string.network_this_connection), linkFacts)
                }
                if (scanFacts.isNotEmpty()) item {
                    PrimaryFactsSection(stringResource(R.string.network_scan), scanFacts)
                }
                if (unkeyed.isNotEmpty()) item {
                    PrimaryFactsSection(stringResource(R.string.network_primary_result), unkeyed)
                }
                result.cacheAgeMs?.let { age -> item { MeasurementAge(age) } }
                val aps = result.accessPoints
                if (aps.isEmpty()) {
                    item { FloeText(stringResource(R.string.network_no_ap), style = Floe.typography.body) }
                } else {
                    // Actual AP rows (name, RSSI, channel/frequency) lead the
                    // page; the channel distribution is a secondary summary.
                    items(aps, key = { it.identity }) { ap -> AccessPointRow(ap) }
                }
                for (band in listOf(24, 5, 6)) {
                    val bandAps = aps.filter { ap -> ap.frequencyMHz?.let { bandForFrequency(it) == band } == true }
                    if (bandAps.isNotEmpty()) item {
                        ChannelDistribution(band, bandAps)
                    }
                }
                item { FloeCapsuleButton(stringResource(R.string.network_location), onOpenLocationSettings) }
            } else {
                if (primary.isNotEmpty()) item {
                    PrimaryFactsSection(stringResource(R.string.network_primary_result), primary)
                }
                result.cacheAgeMs?.let { age -> item { MeasurementAge(age) } }
            }
            item { ObservationLimitations(result) }
            item { ObservationDetailsAction(onDetails) }
        }
    }
}

@Composable
internal fun RunStopRow(
    busy: Boolean, isRunning: Boolean, stopping: Boolean, startLabel: Boolean,
    onStart: () -> Unit, onStop: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        FloeCapsuleButton(
            label = stringResource(if (startLabel) R.string.network_start else R.string.network_refresh),
            onClick = onStart, enabled = !busy, prominent = true, modifier = Modifier.weight(1f),
        )
        if (isRunning) {
            FloeCapsuleButton(
                label = stringResource(if (stopping) R.string.network_stopping else R.string.network_stop),
                onClick = onStop, enabled = !stopping, modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
internal fun RunningElapsed(running: Boolean, stopping: Boolean, runningLabel: String) {
    var seconds by remember(running) { mutableIntStateOf(0) }
    LaunchedEffect(running) {
        if (running) {
            while (true) {
                delay(1_000L)
                seconds += 1
            }
        }
    }
    val text = when {
        stopping -> stringResource(R.string.network_stopping)
        running && seconds > 0 -> "$runningLabel · ${seconds}s"
        else -> runningLabel
    }
    FloeText(text, style = Floe.typography.body, color = Floe.colors.secondaryLabel)
}

@Composable
internal fun ObservationHeader(result: NetworkObservationUi) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FloeDivider()
        FloeText(statusTitle(result.status), style = Floe.typography.bodyEmphasized)
        if (result.measuredAt.isNotBlank()) {
            FloeText(
                stringResource(R.string.network_measured, result.measuredAt),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
            )
        }
    }
}

@Composable
internal fun PermissionSection(result: NetworkObservationUi, busy: Boolean, onPermission: (List<String>) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FloeText(stringResource(R.string.network_permission_hint), style = Floe.typography.body)
        FloeCapsuleButton(
            stringResource(R.string.network_permission),
            { onPermission(result.missingPermissions) },
            enabled = !busy,
        )
    }
}

@Composable
internal fun ObservationLimitations(result: NetworkObservationUi) {
    result.limitations.forEach { text ->
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

@Composable
internal fun ObservationDetailsAction(onDetails: () -> Unit) {
    FloeCapsuleButton(stringResource(R.string.network_details), onDetails)
}

@Composable
internal fun FactLine(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        FloeText(label, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        SelectionContainer { FloeText(value, style = Floe.typography.bodyEmphasized) }
    }
}

/** The measured answer, in a stable display order. Actual values only. */
@Composable
internal fun PrimaryFactsSection(title: String, facts: List<NetworkFactUi>) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        FloeText(title, style = Floe.typography.section)
        facts.forEach { fact ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                FloeText(fact.label, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                SelectionContainer { FloeText(fact.value, style = Floe.typography.bodyEmphasized) }
            }
        }
    }
}

/**
 * Scan freshness is an age AT MEASUREMENT, not an age "now": the service
 * reports how old the scan already was when the observation was captured.
 */
@Composable
private fun MeasurementAge(ageMs: Long) {
    val age = ageMs.coerceAtLeast(0)
    val text = if (age < 1000) {
        stringResource(R.string.network_scan_age_under_second)
    } else {
        val seconds = (age / 1000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        pluralStringResource(R.plurals.network_scan_age_seconds, seconds, seconds)
    }
    FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
}

@Composable
private fun AccessPointRow(ap: WifiAccessPointUi) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FloeDivider()
        FloeText(ap.name.ifBlank { stringResource(R.string.network_hidden) }, style = Floe.typography.bodyEmphasized)
        val unavailable = stringResource(R.string.network_missing)
        FloeText(
            listOfNotNull(ap.signalDbm?.let { "$it dBm" }, ap.frequencyMHz?.let { "$it MHz" }, ap.channel?.let { "${stringResource(R.string.network_channel)} $it" }).joinToString(" · ").ifBlank { unavailable },
            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
        )
        ap.security?.takeIf { it.isNotBlank() }?.let { FloeText(it, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
        if (ap.signalHistoryDbm.size >= 2) {
            FloeText(
                pluralStringResource(
                    R.plurals.network_signal_history,
                    ap.signalHistoryDbm.size,
                    ap.signalHistoryDbm.size,
                ),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
            )
            val accent = Floe.colors.accent
            val history = ap.signalHistoryDbm
            Canvas(Modifier.fillMaxWidth().height(56.dp).semantics { contentDescription = history.joinToString(", ") + " dBm" }) {
                fun point(index: Int): Offset = Offset(
                    size.width * index / (history.size - 1),
                    size.height * (1f - ((history[index] + 100f) / 70f).coerceIn(0f, 1f)),
                )
                for (index in 1 until history.size) drawLine(accent, point(index - 1), point(index), 2.dp.toPx(), StrokeCap.Round)
            }
        }
    }
}

internal fun bandForFrequency(frequency: Int): Int? = when (frequency) {
    in 2400..2500 -> 24
    in 4900..5924 -> 5
    in 5925..7125 -> 6
    else -> null
}

@Composable
private fun ChannelDistribution(band: Int, aps: List<WifiAccessPointUi>) {
    val label = stringResource(when (band) { 24 -> R.string.network_band_24; 5 -> R.string.network_band_5; else -> R.string.network_band_6 })
    val accent = Floe.colors.accent
    val separator = Floe.colors.separator
    val description = aps.mapNotNull { ap -> ap.channel?.let { channel -> "$channel: ${ap.signalDbm ?: return@mapNotNull null} dBm" } }.joinToString(", ")
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FloeText("${stringResource(R.string.network_channels)} · $label", style = Floe.typography.bodyEmphasized)
        Canvas(Modifier.fillMaxWidth().height(112.dp).semantics { contentDescription = "$label $description" }) {
            val low = (aps.mapNotNull { it.frequencyMHz }.minOrNull() ?: 0).toFloat() - 10f
            val high = (aps.mapNotNull { it.frequencyMHz }.maxOrNull() ?: 0).toFloat() + 10f
            drawLine(separator, Offset(0f, size.height), Offset(size.width, size.height))
            aps.forEach { ap ->
                val frequency = ap.frequencyMHz ?: return@forEach
                val signal = ap.signalDbm ?: return@forEach
                val x = ((frequency - low) / (high - low)).coerceIn(0f, 1f) * size.width
                val y = size.height * (1f - ((signal + 100f) / 70f).coerceIn(0f, 1f))
                drawLine(accent.copy(alpha = 0.7f), Offset(x, size.height), Offset(x, y), strokeWidth = 5.dp.toPx(), cap = StrokeCap.Round)
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            FloeText("${(aps.mapNotNull { it.frequencyMHz }.minOrNull() ?: 0) - 10} MHz", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            FloeText("−100 … −30 dBm", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            FloeText("${(aps.mapNotNull { it.frequencyMHz }.maxOrNull() ?: 0) + 10} MHz", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

@Composable
private fun pageTitle(page: NetworkPage): String = stringResource(when (page) {
    NetworkPage.OVERVIEW -> R.string.network_overview
    NetworkPage.WIFI -> R.string.network_wifi
    NetworkPage.LAN -> R.string.network_lan
    NetworkPage.SPEED -> R.string.network_speed
    NetworkPage.DNS -> R.string.network_dns
    NetworkPage.PING -> R.string.network_ping
    NetworkPage.TCP -> R.string.network_tcp
    NetworkPage.HTTPS -> R.string.network_https
})

@Composable
internal fun statusTitle(status: String): String = stringResource(when (status) {
    "ok" -> R.string.network_status_ok
    "partial" -> R.string.network_status_partial
    "permissionRequired" -> R.string.network_status_permissionRequired
    "unsupported" -> R.string.network_status_unsupported
    "cancelled" -> R.string.network_status_cancelled
    "timeout" -> R.string.network_status_timeout
    "error" -> R.string.network_status_error
    else -> R.string.network_status_unavailable
})
