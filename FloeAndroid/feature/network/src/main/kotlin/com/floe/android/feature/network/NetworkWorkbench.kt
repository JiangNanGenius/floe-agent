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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.design.*

/** Stable native shell: categories on tablets, list → detail → list on phones. */
@Composable
fun NetworkWorkbench(
    state: NetworkWorkbenchState,
    compact: Boolean,
    onExecute: (NetworkPage, Map<String, String>) -> Unit,
    onCancel: () -> Unit,
    onPermission: (List<String>) -> Unit,
    onOpenLocationSettings: () -> Unit,
    onNavigate: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var selection by rememberSaveable { mutableStateOf<String?>(null) }
    var details by rememberSaveable { mutableStateOf<String?>(null) }
    val page = selection?.let { saved -> NetworkPage.entries.firstOrNull { it.name == saved } }
        ?: if (compact) null else NetworkPage.OVERVIEW
    val back: () -> Unit = { if (compact && page != null) selection = null else onNavigate() }
    BackHandler(enabled = compact && page != null, onBack = back)
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = if (compact && page != null) pageTitle(page) else stringResource(R.string.network_title),
            navigation = {
                FloeCircleButton(
                    icon = if (compact && page != null) FloeIcons.ChevronBack else FloeIcons.SidebarToggle,
                    contentDescription = stringResource(R.string.network_back), onClick = back,
                )
            },
            showHairline = true,
        )
        Row(Modifier.weight(1f)) {
            if (!compact || page == null) {
                Column(
                    Modifier.then(if (compact) Modifier.fillMaxWidth() else Modifier.width(220.dp))
                        .fillMaxHeight().background(Floe.colors.groupedSurface).verticalScroll(rememberScrollState())
                        .padding(vertical = 16.dp),
                ) {
                    NetworkPage.entries.forEach { item ->
                        FloeSidebarRow(
                            icon = when (item) {
                                NetworkPage.OVERVIEW, NetworkPage.WIFI -> FloeIcons.Antenna
                                NetworkPage.DNS -> FloeIcons.Magnifier
                                NetworkPage.PING -> FloeIcons.Gauge
                                NetworkPage.TCP -> FloeIcons.Terminal
                                NetworkPage.HTTPS -> FloeIcons.ShieldCheck
                            },
                            label = pageTitle(item), selected = item == page,
                            onClick = { selection = item.name }, modifier = Modifier.padding(horizontal = 10.dp),
                        )
                    }
                }
            }
            if (!compact) FloeVerticalDivider()
            if (page != null) {
                NetworkDetail(
                    page = page, result = state.results[page], busy = state.running != null,
                    isRunning = state.running == page, onExecute = { onExecute(page, it) },
                    onCancel = onCancel, onPermission = onPermission,
                    onOpenLocationSettings = onOpenLocationSettings, onDetails = { details = it },
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
    FloePageSheet(
        visible = details != null, onDismiss = { details = null },
        widthFraction = if (compact) 1f else 0.78f, heightFraction = 0.85f,
        placement = if (compact) FloeSheetPlacement.BOTTOM else FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize()) {
            FloeToolbar(title = stringResource(R.string.network_details), actions = {
                FloeCircleButton(FloeIcons.Xmark, stringResource(R.string.network_close), { details = null })
            }, showHairline = true)
            SelectionContainer(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp)) {
                FloeText(details.orEmpty(), style = Floe.typography.evidence)
            }
        }
    }
}

@Composable
private fun NetworkDetail(
    page: NetworkPage, result: NetworkObservationUi?, busy: Boolean, isRunning: Boolean,
    onExecute: (Map<String, String>) -> Unit, onCancel: () -> Unit,
    onPermission: (List<String>) -> Unit, onOpenLocationSettings: () -> Unit,
    onDetails: (String) -> Unit, modifier: Modifier,
) {
    var target by rememberSaveable(page) { mutableStateOf("") }
    var port by rememberSaveable(page) { mutableStateOf("443") }
    var error by rememberSaveable(page) { mutableStateOf(false) }
    val validPort = port.toIntOrNull()?.let { it in 1..65535 } == true
    val run: () -> Unit = {
        error = (page.needsTarget && target.isBlank()) || (page == NetworkPage.TCP && !validPort)
        if (!error) {
            onExecute(buildMap {
                if (page.needsTarget) put(if (page == NetworkPage.HTTPS) "url" else "host", target.trim())
                if (page == NetworkPage.TCP) put("port", port)
                if (page == NetworkPage.WIFI) put("refresh", "true")
            })
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
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FloeCapsuleButton(
                    label = stringResource(if (result == null || page.needsTarget) R.string.network_start else R.string.network_refresh),
                    onClick = run, enabled = !busy, prominent = true, modifier = Modifier.weight(1f),
                )
                if (isRunning) FloeCapsuleButton(stringResource(R.string.network_stop), onCancel, Modifier.weight(1f))
            }
        }
        if (isRunning) item { FloeText(stringResource(R.string.network_busy), style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
        if (result == null) {
            item { FloeText(stringResource(R.string.network_no_data), style = Floe.typography.body, color = Floe.colors.secondaryLabel) }
        } else {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    FloeDivider()
                    FloeText(statusTitle(result.status), style = Floe.typography.bodyEmphasized)
                    if (result.measuredAt.isNotBlank()) FloeText(stringResource(R.string.network_measured, result.measuredAt), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    result.cacheAgeMs?.takeIf { it > 0 }?.let {
                        FloeText(stringResource(R.string.network_cache, it / 1000), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    }
                }
            }
            if (result.status == "permissionRequired") item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeText(stringResource(R.string.network_permission_hint), style = Floe.typography.body)
                    FloeCapsuleButton(stringResource(R.string.network_permission), { onPermission(result.missingPermissions) }, enabled = !busy)
                }
            }
            items(result.facts) { fact ->
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    FloeText(fact.label, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    SelectionContainer { FloeText(fact.value, style = Floe.typography.body) }
                }
            }
            if (page == NetworkPage.WIFI) {
                val aps = result.accessPoints
                if (aps.isEmpty()) item { FloeText(stringResource(R.string.network_no_ap), style = Floe.typography.body) }
                for (band in listOf(24, 5, 6)) {
                    val bandAps = aps.filter { ap -> ap.frequencyMHz?.let { bandForFrequency(it) == band } == true }
                    if (bandAps.isNotEmpty()) item {
                        ChannelDistribution(band, bandAps)
                    }
                }
                items(aps, key = { it.identity }) { ap -> AccessPointRow(ap) }
                item { FloeCapsuleButton(stringResource(R.string.network_location), onOpenLocationSettings) }
            }
            items(result.limitations) { text -> FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel) }
            if (result.details.isNotEmpty()) item {
                FloeCapsuleButton(stringResource(R.string.network_details), { onDetails(result.details) })
            }
        }
    }
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
        ap.ageMs?.takeIf { it > 0 }?.let { age ->
            FloeText(stringResource(R.string.network_cache, age / 1000), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        if (ap.signalHistoryDbm.size >= 2) {
            FloeText(stringResource(R.string.network_signal_history, ap.signalHistoryDbm.size), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
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
    NetworkPage.DNS -> R.string.network_dns
    NetworkPage.PING -> R.string.network_ping
    NetworkPage.TCP -> R.string.network_tcp
    NetworkPage.HTTPS -> R.string.network_https
})

@Composable
private fun statusTitle(status: String): String = stringResource(when (status) {
    "ok" -> R.string.network_status_ok
    "partial" -> R.string.network_status_partial
    "permissionRequired" -> R.string.network_status_permissionRequired
    "unsupported" -> R.string.network_status_unsupported
    "cancelled" -> R.string.network_status_cancelled
    "timeout" -> R.string.network_status_timeout
    "error" -> R.string.network_status_error
    else -> R.string.network_status_unavailable
})
