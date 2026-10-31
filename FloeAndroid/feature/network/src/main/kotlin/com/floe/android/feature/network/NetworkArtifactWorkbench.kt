// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.floe.android.core.networkmonitor.CoverageLimits
import com.floe.android.design.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Callbacks owned by the App host; the feature module never touches SAF or files. */
class NetworkArtifactCallbacks(
    val onPickPcap: (Boolean) -> Unit,
    val onSelectPcap: (String) -> Unit,
    val onFilterPcap: (String, PcapFilterQuery) -> Unit,
    val onExportPcap: (String, PcapFilterQuery, PcapExportFormatUi) -> Unit,
    val onDeletePcap: (String) -> Unit,
    val onSetPcapAgentReadable: (String, Boolean) -> Unit,
    val onClosePcap: () -> Unit,
    val onPickFloorplan: () -> Unit,
    val onCreateCoverage: (String) -> Unit,
    val onSelectCoverage: (String) -> Unit,
    val onDeleteCoverage: (String) -> Unit,
    val onCloseCoverage: () -> Unit,
    val onSampleCoverage: (String, CoverageSampleRequest) -> Unit,
    val onExportCoverage: (String, CoverageExportFormatUi) -> Unit,
    val onSetCoverageAgentReadable: (String, Boolean) -> Unit,
    val onPermission: (List<String>) -> Unit,
    val onCancelActive: () -> Unit,
)

private enum class ArtifactTab { CAPTURES, COVERAGE }

/**
 * Offline captures and Wi-Fi coverage. Phone shows one column; tablet shows a
 * compact list beside the selected detail. The existing workbench still owns
 * the outer shell and back behavior; this panel only owns its internal
 * list/detail transition.
 */
@Composable
fun NetworkArtifactWorkbench(
    state: NetworkArtifactState,
    compact: Boolean,
    callbacks: NetworkArtifactCallbacks,
    modifier: Modifier = Modifier,
) {
    var tab by rememberSaveable { mutableStateOf(ArtifactTab.CAPTURES.name) }
    val selectedTab = ArtifactTab.entries.firstOrNull { it.name == tab } ?: ArtifactTab.CAPTURES
    val pcapDetail = state.pcap.selectedID != null
    val coverageDetail = state.coverage.selectedID != null
    val detailOpen = (selectedTab == ArtifactTab.CAPTURES && pcapDetail) ||
        (selectedTab == ArtifactTab.COVERAGE && coverageDetail)
    BackHandler(enabled = detailOpen) {
        if (selectedTab == ArtifactTab.CAPTURES) callbacks.onClosePcap() else callbacks.onCloseCoverage()
    }
    Column(modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 16.dp, top = 14.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (detailOpen) {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.network_artifact_back),
                    onClick = {
                        if (selectedTab == ArtifactTab.CAPTURES) callbacks.onClosePcap()
                        else callbacks.onCloseCoverage()
                    },
                )
                Spacer(Modifier.width(8.dp))
            }
            FloeText(
                stringResource(
                    if (selectedTab == ArtifactTab.CAPTURES) R.string.network_artifact_captures
                    else R.string.network_artifact_coverage,
                ),
                style = Floe.typography.section,
                modifier = Modifier.weight(1f),
            )
            if (state.pcap.busy || state.coverage.busy || state.coverage.sampling) {
                FloeActivityIndicator(description = stringResource(R.string.network_artifact_working))
            }
        }
        FloeSegmented(
            options = listOf(
                stringResource(R.string.network_artifact_captures),
                stringResource(R.string.network_artifact_coverage),
            ),
            selectedIndex = selectedTab.ordinal,
            onSelect = { index ->
                tab = ArtifactTab.entries[index].name
                if (index == ArtifactTab.CAPTURES.ordinal) callbacks.onCloseCoverage()
                else callbacks.onClosePcap()
            },
            modifier = Modifier.padding(horizontal = 20.dp, vertical = 4.dp),
        )
        FloeDivider(Modifier.padding(top = 8.dp))
        when (selectedTab) {
            ArtifactTab.CAPTURES -> {
                if (compact) {
                    if (pcapDetail) PcapDetail(state.pcap, callbacks)
                    else PcapList(state.pcap, callbacks)
                } else {
                    Row(Modifier.weight(1f)) {
                        PcapList(state.pcap, callbacks, Modifier.width(280.dp).fillMaxHeight())
                        FloeVerticalDivider()
                        if (pcapDetail) PcapDetail(state.pcap, callbacks, Modifier.weight(1f))
                        else ArtifactEmpty(stringResource(R.string.network_artifact_capture_select))
                    }
                }
            }
            ArtifactTab.COVERAGE -> {
                if (compact) {
                    if (coverageDetail) CoverageDetail(state.coverage, callbacks)
                    else CoverageList(state.coverage, callbacks)
                } else {
                    Row(Modifier.weight(1f)) {
                        CoverageList(state.coverage, callbacks, Modifier.width(280.dp).fillMaxHeight())
                        FloeVerticalDivider()
                        if (coverageDetail) CoverageDetail(state.coverage, callbacks, Modifier.weight(1f))
                        else ArtifactEmpty(stringResource(R.string.network_artifact_coverage_select))
                    }
                }
            }
        }
    }
}

@Composable
private fun ArtifactEmpty(text: String) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        FloeText(text, style = Floe.typography.body, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun PcapList(
    state: PcapArtifactState,
    callbacks: NetworkArtifactCallbacks,
    modifier: Modifier = Modifier,
) {
    var detailed by rememberSaveable { mutableStateOf(false) }
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(stringResource(R.string.network_artifact_capture_intro), style = Floe.typography.body)
                FloeCheckboxRow(
                    label = stringResource(R.string.network_artifact_capture_detailed),
                    checked = detailed,
                    onCheckedChange = { detailed = it },
                )
                FloeText(
                    stringResource(if (detailed) R.string.network_artifact_capture_detailed_note
                    else R.string.network_artifact_capture_redacted_note),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                FloeCapsuleButton(
                    stringResource(R.string.network_artifact_capture_import),
                    onClick = { callbacks.onPickPcap(detailed) },
                    prominent = true,
                    enabled = !state.importing && !state.busy,
                )
                if (state.importing) {
                    FloeStatusLine(
                        FloeIcons.Clock,
                        stringResource(R.string.network_artifact_capture_importing),
                        Floe.colors.secondaryLabel,
                    )
                    FloeCapsuleButton(
                        stringResource(R.string.network_artifact_cancel_work),
                        onClick = callbacks.onCancelActive,
                    )
                }
                state.failure?.let { ArtifactFailureLine(it) }
                state.exportedBytes?.let {
                    FloeText(stringResource(R.string.network_artifact_exported, it),
                        style = Floe.typography.metadata)
                }
            }
        }
        if (state.analyses.isEmpty() && !state.importing) {
            item { ArtifactEmpty(stringResource(R.string.network_artifact_capture_none)) }
        }
        items(state.analyses, key = { it.analysisID }) { item ->
            PcapRow(item, selected = item.analysisID == state.selectedID) {
                callbacks.onSelectPcap(item.analysisID)
            }
        }
    }
}

@Composable
private fun PcapRow(item: PcapAnalysisItemUi, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(if (selected) Floe.colors.fillTertiary else Color.Transparent,
                FloeLayout.SidebarSelectionShape)
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        IconGlyph(FloeIcons.ChartBar, Floe.colors.accent)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            FloeText(item.sourceLabel ?: item.analysisID.take(8), style = Floe.typography.bodyEmphasized,
                maxLines = 1)
            FloeText(
                stringResource(
                    R.string.network_artifact_capture_row,
                    item.format.uppercase(), item.packetCount, item.flowCount,
                    NetworkMeasureFormat.bytes(item.sourceBytes),
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 2,
            )
            FloeText(NetworkArtifactFormat.timestamp(item.createdAtEpochMillis),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        PcapStatusPill(item.status)
    }
}

@Composable
private fun PcapStatusPill(status: String) {
    val (text, tone) = when (status) {
        "ok" -> stringResource(R.string.network_artifact_status_ok) to FloeBadgeTone.SUCCESS
        "partial" -> stringResource(R.string.network_artifact_status_partial) to FloeBadgeTone.PENDING
        else -> stringResource(R.string.network_artifact_status_failed) to FloeBadgeTone.DESTRUCTIVE
    }
    FloeBadgePill(text, tone)
}

@Composable
private fun PcapDetail(
    state: PcapArtifactState,
    callbacks: NetworkArtifactCallbacks,
    modifier: Modifier = Modifier,
) {
    val analysis = state.selected ?: run {
        ArtifactEmpty(stringResource(R.string.network_artifact_capture_select))
        return
    }
    var filters by remember(analysis.item.analysisID, analysis.filters) {
        mutableStateOf(PcapFilterForm.values(analysis.filters))
    }
    var filterErrors by remember(analysis.item.analysisID) { mutableStateOf(emptySet<String>()) }
    var confirmDelete by remember(analysis.item.analysisID) { mutableStateOf(false) }
    val toggle: (String, Set<String>, (Set<String>) -> Unit) -> Unit = { value, values, apply ->
        apply(if (value in values) values - value else values + value)
    }
    LazyColumn(
        modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeText(analysis.item.sourceLabel ?: analysis.item.analysisID.take(8),
                        style = Floe.typography.section, modifier = Modifier.weight(1f))
                    PcapStatusPill(analysis.item.status)
                }
                FloeText(
                    stringResource(
                        R.string.network_artifact_capture_summary,
                        analysis.item.format.uppercase(), analysis.item.packetCount,
                        analysis.item.flowCount, NetworkMeasureFormat.bytes(analysis.item.sourceBytes),
                        analysis.item.parseMillis,
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                analysis.startEpochMillis?.let {
                    FloeText(stringResource(
                        R.string.network_artifact_capture_span,
                        NetworkArtifactFormat.timestamp(it),
                        NetworkArtifactFormat.timestamp(analysis.endEpochMillis ?: it),
                    ), style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
                FloeText(stringResource(R.string.network_artifact_capture_privacy,
                    stringResource(if (analysis.item.detailed) R.string.network_artifact_privacy_detailed
                    else R.string.network_artifact_privacy_redacted)),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeCheckboxRow(
                    label = stringResource(R.string.network_artifact_agent_read),
                    checked = analysis.item.agentReadable,
                    onCheckedChange = {
                        callbacks.onSetPcapAgentReadable(analysis.item.analysisID, it)
                    },
                )
                FloeText(stringResource(R.string.network_artifact_agent_read_note),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
        }
        item {
            FloeText(stringResource(R.string.network_artifact_filters), style = Floe.typography.section)
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                FloeText(stringResource(R.string.network_artifact_protocols),
                    style = Floe.typography.bodyEmphasized)
                PcapFilterForm.PROTOCOLS.forEach { protocol ->
                    FloeCheckboxRow(
                        label = protocolLabel(protocol),
                        checked = protocol in filters.protocols,
                        onCheckedChange = {
                            toggle(protocol, filters.protocols) { filters = filters.copy(protocols = it) }
                        },
                    )
                }
                FloeText(stringResource(R.string.network_artifact_services),
                    style = Floe.typography.bodyEmphasized)
                PcapFilterForm.SERVICES.forEach { service ->
                    FloeCheckboxRow(
                        label = serviceLabel(service),
                        checked = service in filters.services,
                        onCheckedChange = {
                            toggle(service, filters.services) { filters = filters.copy(services = it) }
                        },
                    )
                }
            }
        }
        item {
            FloePlainFormField(
                label = stringResource(R.string.network_artifact_address),
                value = filters.address,
                onValueChange = { filters = filters.copy(address = it.take(64)); filterErrors = emptySet() },
                isError = "address" in filterErrors,
            )
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloePlainFormField(
                    label = stringResource(R.string.network_artifact_port),
                    value = filters.port,
                    onValueChange = { filters = filters.copy(port = it.take(5)); filterErrors = emptySet() },
                    isError = "port" in filterErrors,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                FloePlainFormField(
                    label = stringResource(R.string.network_artifact_start_seconds),
                    value = filters.startSeconds,
                    onValueChange = { filters = filters.copy(startSeconds = it.take(12)); filterErrors = emptySet() },
                    isError = "time" in filterErrors,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
                FloePlainFormField(
                    label = stringResource(R.string.network_artifact_end_seconds),
                    value = filters.endSeconds,
                    onValueChange = { filters = filters.copy(endSeconds = it.take(12)); filterErrors = emptySet() },
                    isError = "time" in filterErrors,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f),
                )
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                FloeCapsuleButton(
                    stringResource(R.string.network_artifact_apply_filters),
                    onClick = {
                        val parsed = PcapFilterForm.parse(filters)
                        filterErrors = parsed.errors
                        parsed.query?.let { callbacks.onFilterPcap(analysis.item.analysisID, it) }
                    },
                    enabled = !state.busy,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleButton(
                    stringResource(R.string.network_artifact_clear_filters),
                    onClick = {
                        val empty = PcapFilterValues()
                        filters = empty
                        filterErrors = emptySet()
                        callbacks.onFilterPcap(analysis.item.analysisID, PcapFilterQuery(
                            emptySet(), emptySet(), null, null, null, null))
                    },
                    enabled = !state.busy,
                    modifier = Modifier.weight(1f),
                )
            }
            if (filterErrors.isNotEmpty()) {
                FloeText(stringResource(R.string.network_artifact_filter_invalid),
                    style = Floe.typography.metadata, color = Floe.colors.destructive)
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                MetricText(stringResource(R.string.network_artifact_matched_flows),
                    analysis.matchedFlows.toString(), Modifier.weight(1f))
                MetricText(stringResource(R.string.network_artifact_matched_packets),
                    analysis.matchedPackets.toString(), Modifier.weight(1f))
                MetricText(stringResource(R.string.network_artifact_matched_bytes),
                    NetworkMeasureFormat.bytes(analysis.matchedBytes), Modifier.weight(1f))
            }
        }
        if (analysis.timeline.isNotEmpty()) {
            item {
                FloeText(stringResource(R.string.network_artifact_timeline), style = Floe.typography.section)
                TimelineBars(analysis.timeline)
            }
        }
        item {
            FloeText(stringResource(R.string.network_artifact_protocols), style = Floe.typography.section)
            analysis.protocols.forEach {
                Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                    FloeText(it.protocol, style = Floe.typography.metadata, modifier = Modifier.weight(1f))
                    FloeText("${it.packets} · ${NetworkMeasureFormat.bytes(it.bytes)}",
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
        if (analysis.flows.isNotEmpty()) {
            item {
                FloeText(stringResource(R.string.network_artifact_flows), style = Floe.typography.section)
            }
            items(analysis.flows.take(120)) { flow ->
                FlowRow(flow)
            }
        }
        if (analysis.dns.isNotEmpty()) {
            item { FloeText(stringResource(R.string.network_artifact_dns), style = Floe.typography.section) }
            items(analysis.dns.take(40)) { dns ->
                FloeText(
                    stringResource(R.string.network_artifact_dns_row,
                        dns.direction, dns.name, dns.recordType, dns.responseCode ?: 0),
                    style = Floe.typography.evidence,
                )
            }
        }
        if (analysis.http.isNotEmpty()) {
            item { FloeText(stringResource(R.string.network_artifact_http), style = Floe.typography.section) }
            items(analysis.http.take(40)) { http ->
                FloeText(
                    stringResource(R.string.network_artifact_http_row,
                        http.direction, http.methodOrStatus, http.host ?: "", http.path ?: ""),
                    style = Floe.typography.evidence,
                )
            }
        }
        if (analysis.limitations.isNotEmpty()) {
            item {
                FloeText(stringResource(R.string.network_artifact_limitations), style = Floe.typography.section)
                analysis.limitations.forEach {
                    FloeText("• $it", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleButton(stringResource(R.string.network_artifact_export_json), {
                    callbacks.onExportPcap(analysis.item.analysisID, analysis.filters, PcapExportFormatUi.JSON)
                }, enabled = !state.busy, modifier = Modifier.weight(1f))
                FloeCapsuleButton(stringResource(R.string.network_artifact_export_markdown), {
                    callbacks.onExportPcap(analysis.item.analysisID, analysis.filters, PcapExportFormatUi.MARKDOWN)
                }, enabled = !state.busy, modifier = Modifier.weight(1f))
                FloeCapsuleButton(stringResource(R.string.network_artifact_export_csv), {
                    callbacks.onExportPcap(analysis.item.analysisID, analysis.filters, PcapExportFormatUi.CSV)
                }, enabled = !state.busy, modifier = Modifier.weight(1f))
            }
        }
        item {
            FloeCapsuleButton(stringResource(R.string.network_artifact_delete), {
                confirmDelete = true
            }, enabled = !state.busy, prominent = false)
            state.failure?.let { ArtifactFailureLine(it) }
            state.exportedBytes?.let {
                FloeText(stringResource(R.string.network_artifact_exported, it),
                    style = Floe.typography.metadata)
            }
        }
    }
    if (confirmDelete) {
        FloeConfirmDialog(
            title = stringResource(R.string.network_artifact_delete_capture_title),
            message = stringResource(R.string.network_artifact_delete_capture_message),
            confirmLabel = stringResource(R.string.network_artifact_delete),
            dismissLabel = stringResource(R.string.network_artifact_cancel),
            onConfirm = { confirmDelete = false; callbacks.onDeletePcap(analysis.item.analysisID) },
            onDismiss = { confirmDelete = false },
        )
    }
}

@Composable
private fun MetricText(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        FloeText(label, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        FloeText(value, style = Floe.typography.bodyEmphasized)
    }
}

@Composable
private fun TimelineBars(rows: List<PcapTimelineRowUi>) {
    val max = rows.maxOfOrNull { it.packets }?.coerceAtLeast(1L) ?: 1L
    val accent = Floe.colors.accent
    Canvas(Modifier.fillMaxWidth().height(72.dp)) {
        val width = size.width / rows.size.coerceAtLeast(1)
        rows.forEachIndexed { index, row ->
            val fraction = row.packets.toFloat() / max
            drawRect(
                color = accent.copy(alpha = 0.55f),
                topLeft = Offset(index * width, size.height * (1f - fraction)),
                size = Size((width - 1f).coerceAtLeast(1f), size.height * fraction),
            )
        }
    }
}

@Composable
private fun FlowRow(flow: PcapFlowRowUi) {
    FloeText(
        buildString {
            append(flow.protocol)
            append("  ")
            append(flow.source)
            append(flow.sourcePort?.let { ":$it" } ?: "")
            append(" → ")
            append(flow.destination)
            append(flow.destinationPort?.let { ":$it" } ?: "")
            append("  ")
            append(flow.packets)
            append(" / ")
            append(NetworkMeasureFormat.bytes(flow.bytes))
            flow.tcpFlags?.let { append("  ").append(it) }
        },
        style = Floe.typography.evidence,
    )
}

/* ------------------------------- coverage -------------------------------- */

@Composable
private fun CoverageList(
    state: CoverageArtifactState,
    callbacks: NetworkArtifactCallbacks,
    modifier: Modifier = Modifier,
) {
    var newName by rememberSaveable { mutableStateOf("") }
    LazyColumn(modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(stringResource(R.string.network_artifact_coverage_intro), style = Floe.typography.body)
                FloePlainFormField(
                    label = stringResource(R.string.network_artifact_coverage_name),
                    value = newName,
                    onValueChange = { newName = it.take(128) },
                )
                FloeCapsuleButton(
                    stringResource(R.string.network_artifact_coverage_create),
                    onClick = { callbacks.onCreateCoverage(newName.trim()) },
                    prominent = true,
                    enabled = newName.trim().isNotEmpty() && !state.busy,
                )
                state.failure?.let { ArtifactFailureLine(it) }
                state.exportedBytes?.let {
                    FloeText(stringResource(R.string.network_artifact_exported, it),
                        style = Floe.typography.metadata)
                }
            }
        }
        if (state.sessions.isEmpty()) {
            item { ArtifactEmpty(stringResource(R.string.network_artifact_coverage_none)) }
        }
        items(state.sessions, key = { it.sessionID }) { session ->
            Row(
                Modifier.fillMaxWidth()
                    .background(if (session.sessionID == state.selectedID) Floe.colors.fillTertiary
                    else Color.Transparent, FloeLayout.SidebarSelectionShape)
                    .clickable { callbacks.onSelectCoverage(session.sessionID) }
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                IconGlyph(FloeIcons.Antenna, Floe.colors.accent)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    FloeText(session.name, style = Floe.typography.bodyEmphasized, maxLines = 1)
                    FloeText(
                        stringResource(R.string.network_artifact_coverage_row,
                            session.pointCount, session.namedLocations.size,
                            if (session.hasFloorplan) stringResource(R.string.network_artifact_yes)
                            else stringResource(R.string.network_artifact_no)),
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
                    )
                    FloeText(NetworkArtifactFormat.timestamp(session.updatedAtEpochMillis),
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
    }
}

@Composable
private fun CoverageDetail(
    state: CoverageArtifactState,
    callbacks: NetworkArtifactCallbacks,
    modifier: Modifier = Modifier,
) {
    val session = state.selected ?: run {
        ArtifactEmpty(stringResource(R.string.network_artifact_coverage_select))
        return
    }
    var pendingX by remember(session.item.sessionID) { mutableStateOf(0.5) }
    var pendingY by remember(session.item.sessionID) { mutableStateOf(0.5) }
    var label by rememberSaveable(session.item.sessionID) { mutableStateOf("") }
    var probeEnabled by rememberSaveable(session.item.sessionID) { mutableStateOf(false) }
    var probeKindIndex by rememberSaveable(session.item.sessionID) { mutableIntStateOf(0) }
    var probeHost by rememberSaveable(session.item.sessionID) { mutableStateOf("") }
    var probePort by rememberSaveable(session.item.sessionID) { mutableStateOf("443") }
    var probeUrl by rememberSaveable(session.item.sessionID) { mutableStateOf("") }
    var allowMetered by rememberSaveable(session.item.sessionID) { mutableStateOf(false) }
    var errors by remember(session.item.sessionID) { mutableStateOf(emptySet<String>()) }
    var confirmDelete by remember(session.item.sessionID) { mutableStateOf(false) }
    val kinds = CoverageForm.PROBE_KINDS
    val probe = CoverageProbeRequestUi(
        kind = kinds[probeKindIndex.coerceIn(0, kinds.lastIndex)],
        host = probeHost,
        port = probePort,
        endpointUrl = probeUrl,
        allowMetered = allowMetered,
    )
    val bitmap = rememberFloorplanBitmap(session.floorplan?.image)
    LazyColumn(
        modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                FloeText(session.item.name, style = Floe.typography.section)
                FloeText(
                    stringResource(R.string.network_artifact_coverage_summary,
                        session.aggregate.pointCount, session.item.namedLocations.size,
                        session.aggregate.rssiMin ?: 0, session.aggregate.rssiMax ?: 0,
                        session.aggregate.staleCount, session.aggregate.permissionRequiredCount),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
                )
                FloeText(stringResource(R.string.network_artifact_coverage_legend),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                FloeCheckboxRow(
                    label = stringResource(R.string.network_artifact_agent_read),
                    checked = session.item.agentReadable,
                    onCheckedChange = {
                        callbacks.onSetCoverageAgentReadable(session.item.sessionID, it)
                    },
                )
                FloeText(stringResource(R.string.network_artifact_agent_read_note),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                state.failure?.let { ArtifactFailureLine(it) }
                if (state.missingPermissions.isNotEmpty()) {
                    FloeCapsuleButton(
                        stringResource(R.string.network_artifact_permission),
                        onClick = { callbacks.onPermission(state.missingPermissions) },
                    )
                }
            }
        }
        item {
            CoverageCanvas(
                session = session,
                bitmap = bitmap,
                pendingX = pendingX,
                pendingY = pendingY,
                onTap = { x, y -> pendingX = x; pendingY = y },
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeText(stringResource(R.string.network_artifact_coverage_pending,
                    pendingX, pendingY), style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel, modifier = Modifier.weight(1f))
                FloeCapsuleButton(stringResource(R.string.network_artifact_coverage_floorplan), {
                    callbacks.onPickFloorplan()
                }, enabled = !state.busy, modifier = Modifier.widthIn(max = 200.dp))
            }
            FloeText(stringResource(R.string.network_artifact_coverage_tap_hint),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
        item {
            FloePlainFormField(
                label = stringResource(R.string.network_artifact_coverage_location),
                value = label,
                onValueChange = { label = it.take(96) },
            )
        }
        item {
            FloeCheckboxRow(
                label = stringResource(R.string.network_artifact_coverage_probe_enable),
                checked = probeEnabled,
                onCheckedChange = { probeEnabled = it; errors = emptySet() },
            )
            if (probeEnabled) {
                val probeLabels = kinds.map { probeLabel(it) }
                FloeSegmented(
                    options = probeLabels,
                    selectedIndex = probeKindIndex,
                    onSelect = { probeKindIndex = it; errors = emptySet() },
                )
                if (probe.kind == "ping" || probe.kind == "tcp") {
                    FloePlainFormField(
                        label = stringResource(R.string.network_artifact_coverage_probe_host),
                        value = probeHost,
                        onValueChange = { probeHost = it.take(253); errors = emptySet() },
                        isError = "probeHost" in errors,
                    )
                    if (probe.kind == "tcp") {
                        FloePlainFormField(
                            label = stringResource(R.string.network_artifact_coverage_probe_port),
                            value = probePort,
                            onValueChange = { probePort = it.take(5); errors = emptySet() },
                            isError = "probePort" in errors,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        )
                    }
                }
                if (probe.kind == "speedDownload") {
                    FloePlainFormField(
                        label = stringResource(R.string.network_artifact_coverage_probe_url),
                        value = probeUrl,
                        onValueChange = { probeUrl = it.take(4096); errors = emptySet() },
                        isError = "probeUrl" in errors,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    )
                    FloeCheckboxRow(
                        label = stringResource(R.string.network_artifact_coverage_allow_metered),
                        checked = allowMetered,
                        onCheckedChange = { allowMetered = it },
                    )
                }
                FloeText(stringResource(R.string.network_artifact_coverage_probe_consent),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            if (errors.isNotEmpty()) {
                FloeText(stringResource(R.string.network_artifact_coverage_invalid),
                    style = Floe.typography.metadata, color = Floe.colors.destructive)
            }
            FloeCapsuleButton(
                stringResource(if (state.sampling) R.string.network_artifact_coverage_sampling
                else R.string.network_artifact_coverage_sample),
                onClick = {
                    val parsed = CoverageForm.parse(label, pendingX, pendingY, probeEnabled, probe)
                    errors = parsed.errors
                    parsed.request?.let {
                        callbacks.onSampleCoverage(session.item.sessionID, it)
                    }
                },
                prominent = true,
                enabled = !state.sampling && !state.busy,
            )
            if (state.sampling) {
                FloeCapsuleButton(
                    stringResource(R.string.network_artifact_cancel_work),
                    onClick = callbacks.onCancelActive,
                )
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                MetricText(stringResource(R.string.network_artifact_coverage_points),
                    session.aggregate.pointCount.toString(), Modifier.weight(1f))
                MetricText(stringResource(R.string.network_artifact_coverage_estimated),
                    session.aggregate.estimatedCoveragePercent?.let {
                        String.format(java.util.Locale.ROOT, "%.0f%%", it)
                    } ?: "—", Modifier.weight(1f))
                MetricText(stringResource(R.string.network_artifact_coverage_unsampled),
                    session.aggregate.unsampledCells.toString(), Modifier.weight(1f))
            }
        }
        if (session.limitations.isNotEmpty()) {
            item {
                FloeText(stringResource(R.string.network_artifact_limitations), style = Floe.typography.section)
                session.limitations.forEach {
                    FloeText("• $it", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                }
            }
        }
        item {
            FloeText(stringResource(R.string.network_artifact_coverage_samples), style = Floe.typography.section)
        }
        items(session.points, key = { it.pointID }) { point ->
            CoveragePointRow(point)
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FloeCapsuleButton(stringResource(R.string.network_artifact_export_json), {
                    callbacks.onExportCoverage(session.item.sessionID, CoverageExportFormatUi.JSON)
                }, enabled = !state.busy, modifier = Modifier.weight(1f))
                FloeCapsuleButton(stringResource(R.string.network_artifact_export_markdown), {
                    callbacks.onExportCoverage(session.item.sessionID, CoverageExportFormatUi.MARKDOWN)
                }, enabled = !state.busy, modifier = Modifier.weight(1f))
            }
            FloeCapsuleButton(stringResource(R.string.network_artifact_delete),
                { confirmDelete = true }, enabled = !state.busy)
            state.exportedBytes?.let {
                FloeText(stringResource(R.string.network_artifact_exported, it),
                    style = Floe.typography.metadata)
            }
        }
    }
    if (confirmDelete) {
        FloeConfirmDialog(
            title = stringResource(R.string.network_artifact_delete_coverage_title),
            message = stringResource(R.string.network_artifact_delete_coverage_message),
            confirmLabel = stringResource(R.string.network_artifact_delete),
            dismissLabel = stringResource(R.string.network_artifact_cancel),
            onConfirm = { confirmDelete = false; callbacks.onDeleteCoverage(session.item.sessionID) },
            onDismiss = { confirmDelete = false },
        )
    }
}

@Composable
private fun CoverageCanvas(
    session: CoverageSessionUi,
    bitmap: ImageBitmap?,
    pendingX: Double,
    pendingY: Double,
    onTap: (Double, Double) -> Unit,
) {
    val aspect = session.floorplan?.let { it.width.toFloat() / it.height } ?: (4f / 3f)
    val accent = Floe.colors.accent
    Box(
        Modifier.fillMaxWidth()
            .aspectRatio(aspect.coerceIn(0.5f, 2.5f))
            .background(Floe.colors.fillTertiary)
            .pointerInput(session.item.sessionID) {
                detectTapGestures { offset ->
                    if (size.width > 0 && size.height > 0) {
                        onTap(
                            (offset.x / size.width).coerceIn(0f, 1f).toDouble(),
                            (offset.y / size.height).coerceIn(0f, 1f).toDouble(),
                        )
                    }
                }
            },
    ) {
        if (bitmap != null) {
            Image(bitmap, contentDescription = null, modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Fit)
        } else {
            Canvas(Modifier.fillMaxSize()) {
                val columns = CoverageLimits.GRID_COLUMNS
                val rows = CoverageLimits.GRID_ROWS
                val cellWidth = size.width / columns
                val cellHeight = size.height / rows
                session.aggregate.grid.forEach { cell ->
                    val color = gridColor(cell.averageRssiDbm)
                    drawRect(
                        color = color,
                        topLeft = Offset(cell.column * cellWidth, cell.row * cellHeight),
                        size = Size(cellWidth - 1f, cellHeight - 1f),
                    )
                }
            }
        }
        Canvas(Modifier.fillMaxSize()) {
            session.points.forEach { point ->
                val center = Offset(
                    (point.x * size.width).toFloat(),
                    (point.y * size.height).toFloat(),
                )
                drawCircle(color = pointColor(point.level), radius = 7f, center = center)
                drawCircle(color = Color.White, radius = 7f, center = center, style = Stroke(1.5f))
            }
            drawCircle(
                color = accent,
                radius = 10f,
                center = Offset((pendingX * size.width).toFloat(), (pendingY * size.height).toFloat()),
                style = Stroke(2f),
            )
        }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        listOf("strong", "good", "fair", "weak").forEach { level ->
            Row(verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                modifier = Modifier.weight(1f)) {
                Box(Modifier.size(10.dp).background(pointColor(level), FloeLayout.SidebarSelectionShape))
                FloeText(levelLabel(level), style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel)
            }
        }
    }
}

@Composable
private fun CoveragePointRow(point: CoveragePointUi) {
    Column(Modifier.fillMaxWidth().padding(vertical = 5.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(10.dp).background(pointColor(point.level), FloeLayout.SidebarSelectionShape))
            FloeText(point.label ?: stringResource(R.string.network_artifact_coverage_unnamed),
                style = Floe.typography.bodyEmphasized, modifier = Modifier.weight(1f))
            if (point.stale) FloeBadgePill(stringResource(R.string.network_artifact_stale), FloeBadgeTone.PENDING)
            if (point.permissionRequired) FloeBadgePill(
                stringResource(R.string.network_artifact_permission_short), FloeBadgeTone.DESTRUCTIVE)
        }
        FloeText(
            stringResource(R.string.network_artifact_coverage_point_row,
                point.rssiDbm?.toString() ?: "—", point.channel?.toString() ?: "—",
                point.ageMs, point.cachedAgeMs ?: 0L),
            style = Floe.typography.metadata, color = Floe.colors.secondaryLabel,
        )
        point.probe?.let {
            FloeText(stringResource(R.string.network_artifact_coverage_probe_row,
                it.kind, it.status, it.latencyMs ?: 0.0, NetworkArtifactFormat.rate(it.bitsPerSecond)),
                style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
        }
    }
}

@Composable
private fun rememberFloorplanBitmap(bytes: ByteArray?): ImageBitmap? {
    val bitmap by produceState<ImageBitmap?>(initialValue = null, bytes) {
        value = withContext(Dispatchers.IO) {
            bytes?.let { raw ->
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
                var sample = 1
                while (bounds.outWidth / sample > 2048 || bounds.outHeight / sample > 2048) {
                    sample *= 2
                }
                BitmapFactory.decodeByteArray(
                    raw, 0, raw.size,
                    BitmapFactory.Options().apply { inSampleSize = sample },
                )?.asImageBitmap()
            }
        }
    }
    return bitmap
}

@Composable
private fun ArtifactFailureLine(failure: NetworkArtifactFailure) {
    val text = when (failure) {
        NetworkArtifactFailure.SOURCE_TOO_LARGE -> stringResource(R.string.network_artifact_failure_too_large)
        NetworkArtifactFailure.SOURCE_UNAVAILABLE -> stringResource(R.string.network_artifact_failure_source)
        NetworkArtifactFailure.UNSUPPORTED_FORMAT -> stringResource(R.string.network_artifact_failure_format)
        NetworkArtifactFailure.READ_FAILED -> stringResource(R.string.network_artifact_failure_read)
        NetworkArtifactFailure.STORE_FAILED -> stringResource(R.string.network_artifact_failure_store)
        NetworkArtifactFailure.NOT_FOUND -> stringResource(R.string.network_artifact_failure_not_found)
        NetworkArtifactFailure.EXPORT_FAILED -> stringResource(R.string.network_artifact_failure_export)
        NetworkArtifactFailure.CANCELLED -> stringResource(R.string.network_artifact_failure_cancelled)
        NetworkArtifactFailure.PERMISSION_REQUIRED -> stringResource(R.string.network_artifact_failure_permission)
        NetworkArtifactFailure.SCAN_FAILED -> stringResource(R.string.network_artifact_failure_scan)
        NetworkArtifactFailure.FLOORPLAN_TOO_LARGE -> stringResource(R.string.network_artifact_failure_image_size)
        NetworkArtifactFailure.FLOORPLAN_INVALID -> stringResource(R.string.network_artifact_failure_image)
        NetworkArtifactFailure.SESSION_LIMIT -> stringResource(R.string.network_artifact_failure_session_limit)
        NetworkArtifactFailure.CAPTURE_LIMIT -> stringResource(R.string.network_artifact_failure_capture_limit)
        NetworkArtifactFailure.POINT_LIMIT -> stringResource(R.string.network_artifact_failure_point_limit)
        NetworkArtifactFailure.INVALID_INPUT -> stringResource(R.string.network_artifact_failure_input)
    }
    FloeStatusLine(FloeIcons.WarningTriangle, text, Floe.colors.destructive)
}

@Composable
private fun protocolLabel(protocol: String): String = stringResource(
    when (protocol) {
        "tcp" -> R.string.network_artifact_protocol_tcp
        "udp" -> R.string.network_artifact_protocol_udp
        "icmp" -> R.string.network_artifact_protocol_icmp
        else -> R.string.network_artifact_protocol_icmpv6
    },
)

@Composable
private fun serviceLabel(service: String): String = stringResource(
    if (service == "dns") R.string.network_artifact_service_dns else R.string.network_artifact_service_http,
)

@Composable
private fun probeLabel(kind: String): String = stringResource(
    when (kind) {
        "ping" -> R.string.network_artifact_probe_ping
        "tcp" -> R.string.network_artifact_probe_tcp
        "speedDownload" -> R.string.network_artifact_probe_speed
        else -> R.string.network_artifact_probe_none
    },
)

@Composable
private fun levelLabel(level: String): String = stringResource(
    when (level) {
        "strong" -> R.string.network_artifact_level_strong
        "good" -> R.string.network_artifact_level_good
        "fair" -> R.string.network_artifact_level_fair
        else -> R.string.network_artifact_level_weak
    },
)

private fun pointColor(level: String): Color = when (level) {
    "strong" -> Color(0xFF2E8B57)
    "good" -> Color(0xFF6A9E3A)
    "fair" -> Color(0xFFC58A16)
    "weak" -> Color(0xFFB84A3A)
    else -> Color(0xFF8A8A8E)
}

private fun gridColor(averageRssiDbm: Double?): Color = when {
    averageRssiDbm == null -> Color(0x228A8A8E)
    averageRssiDbm >= CoverageLimits.STRONG_RSSI -> Color(0x552E8B57)
    averageRssiDbm >= CoverageLimits.GOOD_RSSI -> Color(0x556A9E3A)
    averageRssiDbm >= CoverageLimits.FAIR_RSSI -> Color(0x55C58A16)
    else -> Color(0x55B84A3A)
}
