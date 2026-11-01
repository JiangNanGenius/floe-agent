// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.design.*
import com.floe.android.feature.network.*
import com.floe.android.host.RuntimeHost
import com.floe.android.host.capture.CaptureStartPreparation
import com.floe.android.host.capture.RawExportPreparation
import com.floe.android.safgateway.*

private data class PendingPcapExport(
    val analysisID: String,
    val query: PcapFilterQuery,
    val format: PcapExportFormatUi,
)

private data class PendingCoverageExport(
    val sessionID: String,
    val format: CoverageExportFormatUi,
)

private data class PendingRawExport(
    val preparation: RawExportPreparation,
)

/** Permission callbacks grant access only; they never replay a diagnostic. */
@Composable
internal fun NetworkWorkbenchDestination(
    host: RuntimeHost?, compact: Boolean, showSidebarToggle: Boolean, onNavigate: () -> Unit,
) {
    if (host == null) {
        FloeUnavailableView(FloeIcons.Antenna, stringResource(R.string.network_workbench), stringResource(R.string.projects_runtime_pending))
        return
    }
    val controller = host.networkWorkbench
    val state by controller.state.collectAsState()
    val artifactController = host.networkArtifact
    val artifactState by artifactController.state.collectAsState()
    val captureController = host.capture
    val captureState by captureController.state.collectAsState()
    val rawCaptureState by captureController.rawState.collectAsState()
    val captureAvailability = captureController.rootAvailability()
    var pendingCaptureConsent by remember { mutableStateOf<String?>(null) }
    val captureConsentLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val sessionId = pendingCaptureConsent
        pendingCaptureConsent = null
        if (sessionId != null) {
            captureController.onConsentResult(
                sessionId,
                result.resultCode == Activity.RESULT_OK,
            )
        }
    }
    fun startCapture(mode: String, detailed: Boolean, minutes: Int) {
        val prepared = if (mode == CaptureMode.ROOT.wire) {
            captureController.requestRootStart(detailed, minutes)
        } else {
            captureController.requestVpnStart(detailed, minutes)
        }
        if (prepared is CaptureStartPreparation.ConsentRequired) {
            pendingCaptureConsent = prepared.sessionId
            runCatching { captureConsentLauncher.launch(prepared.intent) }
                .onFailure { pendingCaptureConsent = null }
        }
    }
    val context = LocalContext.current
    val asked = remember { mutableSetOf<String>() }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
        // No run is captured by a permission prompt. The user starts a fresh
        // measurement after returning, including after rotation/process death.
    }
    val permissionAction: (List<String>) -> Unit = { missing ->
        val lan = "android.permission.ACCESS_LOCAL_NETWORK"
        if (Build.VERSION.SDK_INT >= 37 && lan in missing) {
            host.integrations.localNetwork.runExplicitAction(
                ownerID = controller.ownerID, endpoint = "https://localhost",
                isCurrent = controller::isActive, onDenied = { _ -> }, dispatch = {},
            )
        } else {
            val runtime = missing.filter { permission ->
                permission in setOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION,
                    "android.permission.NEARBY_WIFI_DEVICES") &&
                    context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED &&
                    (permission != "android.permission.NEARBY_WIFI_DEVICES" || Build.VERSION.SDK_INT >= 33)
            }.toSet().toMutableSet()
            // Modern Android requests precise and approximate together.
            if (Manifest.permission.ACCESS_FINE_LOCATION in runtime) runtime += Manifest.permission.ACCESS_COARSE_LOCATION
            val activity = context as? Activity
            val needsSettings = runtime.any { it in asked && activity?.shouldShowRequestPermissionRationale(it) == false }
            if (needsSettings) context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
            else if (runtime.isNotEmpty()) { asked += runtime; launcher.launch(runtime.toTypedArray()) }
        }
    }
    var pendingPcapDetailed by remember { mutableStateOf(false) }
    val pcapPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) artifactController.importPcap(uri, pendingPcapDetailed)
    }
    var pendingPcapExport by remember { mutableStateOf<PendingPcapExport?>(null) }
    val pcapExportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val pending = pendingPcapExport
        pendingPcapExport = null
        if (result.resultCode == Activity.RESULT_OK && pending != null) {
            val uri = SafPickerIntents.resultUriString(result.data)?.let(Uri::parse)
            val flags = SafPickerIntents.resultFlags(result.data)
            if (uri != null && flags and SafGrantFlagBits.GRANT_WRITE != 0) {
                artifactController.exportPcapToUri(uri, pending.analysisID, pending.query, pending.format)
            }
        }
    }
    var pendingRawExport by remember { mutableStateOf<PendingRawExport?>(null) }
    val rawExportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val pending = pendingRawExport
        pendingRawExport = null
        if (pending == null) return@rememberLauncherForActivityResult
        if (result.resultCode != Activity.RESULT_OK) {
            captureController.onRawExportPickerCancelled(pending.preparation.requestId)
            return@rememberLauncherForActivityResult
        }
        val uri = SafPickerIntents.resultUriString(result.data)?.let(Uri::parse)
        val flags = SafPickerIntents.resultFlags(result.data)
        if (uri == null || flags and SafGrantFlagBits.GRANT_WRITE == 0) {
            captureController.onRawExportPickerCancelled(pending.preparation.requestId)
            return@rememberLauncherForActivityResult
        }
        captureController.onRawExportPicked(pending.preparation.requestId, uri)
    }
    fun exportRawCapture(sessionId: String) {
        val prepared = captureController.prepareRawExport(sessionId) ?: return
        pendingRawExport = PendingRawExport(prepared)
        val request = PickRequestSpec(
            requestKey = "network-raw-capture-${prepared.requestId}",
            kind = PickKind.CREATE_DOCUMENT,
            mimeTypes = listOf("application/vnd.tcpdump.pcap"),
            suggestedName = prepared.suggestedName,
            initialDirectory = null,
        )
        runCatching { rawExportLauncher.launch(SafPickerIntents.from(request)) }
            .onFailure {
                pendingRawExport = null
                captureController.onRawExportPickerCancelled(prepared.requestId)
            }
    }
    val floorplanPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) artifactController.saveFloorplan(uri)
    }
    var pendingCoverageExport by remember { mutableStateOf<PendingCoverageExport?>(null) }
    val coverageExportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val pending = pendingCoverageExport
        pendingCoverageExport = null
        if (result.resultCode == Activity.RESULT_OK && pending != null) {
            val uri = SafPickerIntents.resultUriString(result.data)?.let(Uri::parse)
            val flags = SafPickerIntents.resultFlags(result.data)
            if (uri != null && flags and SafGrantFlagBits.GRANT_WRITE != 0) {
                artifactController.exportCoverageToUri(uri, pending.sessionID, pending.format)
            }
        }
    }
    fun pickPcap(detailed: Boolean) {
        pendingPcapDetailed = detailed
        runCatching { pcapPicker.launch(arrayOf("*/*")) }
    }
    fun exportPcap(analysisID: String, query: PcapFilterQuery, format: PcapExportFormatUi) {
        pendingPcapExport = PendingPcapExport(analysisID, query, format)
        val request = PickRequestSpec(
            requestKey = "network-capture-${analysisID.take(8)}-${format.name}",
            kind = PickKind.CREATE_DOCUMENT,
            mimeTypes = listOf(format.mimeType),
            suggestedName = "floe-capture-${analysisID.take(8)}.${format.extension}",
            initialDirectory = null,
        )
        runCatching { pcapExportLauncher.launch(SafPickerIntents.from(request)) }
            .onFailure { pendingPcapExport = null }
    }
    fun exportCoverage(sessionID: String, format: CoverageExportFormatUi) {
        pendingCoverageExport = PendingCoverageExport(sessionID, format)
        val request = PickRequestSpec(
            requestKey = "network-coverage-${sessionID.take(8)}-${format.name}",
            kind = PickKind.CREATE_DOCUMENT,
            mimeTypes = listOf(format.mimeType),
            suggestedName = "floe-wifi-coverage-${sessionID.take(8)}.${format.extension}",
            initialDirectory = null,
        )
        runCatching { coverageExportLauncher.launch(SafPickerIntents.from(request)) }
            .onFailure { pendingCoverageExport = null }
    }
    LaunchedEffect(controller) { controller.enter() }
    LaunchedEffect(artifactController) { artifactController.enter() }
    LaunchedEffect(captureController) {
        captureController.enter()
        captureController.refreshRawCaptures()
    }
    NetworkWorkbench(
        state = state, compact = compact,
        onExecute = controller::execute, onStop = controller::stop,
        onPermission = permissionAction,
        onOpenLocationSettings = { context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) },
        onNavigate = onNavigate, showSidebarToggle = showSidebarToggle,
        diagnosticReport = { observation ->
            (context.applicationContext as? FloeApplication)?.let { app ->
                NetworkDiagnosticReportControls(app.diagnosticReports, observation)
            }
        },
        monitoringLabel = stringResource(com.floe.android.feature.network.R.string.network_monitor),
        monitoringContent = { panelModifier -> NetworkMonitoringDestination(host, panelModifier) },
        artifactLabel = stringResource(com.floe.android.feature.network.R.string.network_artifact_title),
        artifactContent = { panelModifier ->
            NetworkArtifactWorkbench(
                state = artifactState,
                compact = compact,
                captureState = captureState,
                captureAvailability = captureAvailability,
                rawCaptureState = rawCaptureState,
                callbacks = NetworkArtifactCallbacks(
                    onPickPcap = ::pickPcap,
                    onSelectPcap = artifactController::selectPcap,
                    onFilterPcap = artifactController::applyFilters,
                    onExportPcap = ::exportPcap,
                    onDeletePcap = artifactController::deletePcap,
                    onSetPcapAgentReadable = artifactController::setPcapAgentReadable,
                    onClosePcap = artifactController::closePcap,
                    onPickFloorplan = {
                        runCatching { floorplanPicker.launch(arrayOf("image/png", "image/jpeg", "image/webp")) }
                    },
                    onCreateCoverage = artifactController::createCoverageSession,
                    onSelectCoverage = artifactController::selectCoverage,
                    onDeleteCoverage = artifactController::deleteCoverageSession,
                    onCloseCoverage = artifactController::closeCoverage,
                    onSampleCoverage = artifactController::sampleCoverage,
                    onExportCoverage = ::exportCoverage,
                    onSetCoverageAgentReadable = artifactController::setCoverageAgentReadable,
                    onPermission = permissionAction,
                    onCancelActive = artifactController::cancelActiveWork,
                    onCaptureStart = ::startCapture,
                    onCaptureStop = captureController::stop,
                    onOpenCaptureAnalysis = { analysisID ->
                        artifactController.refreshForExternalCapture()
                        artifactController.selectPcap(analysisID)
                    },
                    onRefreshRawCaptures = captureController::refreshRawCaptures,
                    onExportRawCapture = ::exportRawCapture,
                    onCancelRawExport = captureController::cancelRawExport,
                ),
                modifier = panelModifier,
            )
        },
        modifier = Modifier.fillMaxSize(),
    )
}
