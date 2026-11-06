// SPDX-License-Identifier: MPL-2.0
//
// C04A full-window read-only CAD/3D surface. It is a thin renderer over the
// Application-owned C04CadViewerController: the WebView is the pinned
// offline DXF/OCCT/mesh renderer, the controls call the actual camera, and
// the header reuses the existing document back/close geometry. No editor,
// save, modeling or file authority exists here.
package com.floe.android.host.cad

import android.app.Activity
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathBuilder
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.R
import com.floe.android.WorkspaceDocumentHeader
import com.floe.android.WorkspaceDocumentRequest
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionMenu
import com.floe.android.design.FloeActionMenuItem
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeStatusLine
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.design.FloeUnavailableView
import com.floe.android.host.Owner
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs
import kotlinx.coroutines.launch

@Composable
internal fun C04CadViewerDestination(
    controller: C04CadViewerController,
    request: WorkspaceDocumentRequest,
    owner: Owner,
    onBackToFiles: () -> Unit,
    onCloseTask: () -> Unit,
    onOpenFolder: (() -> Unit)? = null,
) {
    val state by controller.state.collectAsState()
    val context = LocalContext.current
    var detailsVisible by rememberSaveable(request.token) { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val dark = Floe.colors.readingSurface.luminance() < 0.5f
    val saveToFiles = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("image/png"),
    ) { uri ->
        if (uri != null) {
            scope.launch {
                runCatching { controller.captureAndExport(request.token, uri) }
            }
        }
    }
    val suggestedCaptureName = cadCaptureName(request.fileName)
    LaunchedEffect(
        request.token, request.path, owner.nativeEpoch, owner.hostGeneration, dark,
    ) {
        controller.open(owner, request.path, request.token, dark = dark)
    }
    DisposableEffect(request.token) {
        onDispose {
            if ((context as? Activity)?.isChangingConfigurations != true) {
                controller.close(request.token)
            }
        }
    }
    val current = when (val value = state) {
        is C04CadViewerState.Opening -> if (value.token == request.token) value else null
        is C04CadViewerState.Rendering -> if (value.token == request.token) value else null
        is C04CadViewerState.Ready -> if (value.token == request.token) value else null
        is C04CadViewerState.Failed -> if (value.token == request.token) value else null
        C04CadViewerState.Idle -> null
    }
    Column(Modifier.fillMaxSize().testTag("workspace.cadDestination")) {
        WorkspaceDocumentHeader(
            fileName = request.fileName,
            onBackToFiles = onBackToFiles,
            onCloseTask = onCloseTask,
        )
        FloeDivider()
        Box(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
            if (current !is C04CadViewerState.Failed) {
                key(request.token) { C04CadViewerSurface(controller, request.token) }
            }
            when (current) {
                null, C04CadViewerState.Idle, is C04CadViewerState.Opening -> LoadingOverlay(
                    text = stringResource(R.string.workspace_document_cad_preparing))
                is C04CadViewerState.Rendering -> LoadingOverlay(
                    text = stringResource(R.string.workspace_document_cad_rendering))
                is C04CadViewerState.Ready -> {
                    SceneChip(
                        state = current,
                        modifier = Modifier
                            .align(Alignment.TopStart)
                            .padding(start = 12.dp, top = 12.dp),
                    )
                    SceneControls(
                        controller = controller,
                        state = current,
                        onSaveToFiles = { saveToFiles.launch(suggestedCaptureName) },
                        onDetails = { detailsVisible = true },
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(horizontal = 8.dp, vertical = 12.dp),
                    )
                }
                is C04CadViewerState.Failed -> FailureOverlay(
                    state = current,
                    onRetry = { controller.retry(request.token, dark = dark) },
                    onDetails = { detailsVisible = true },
                    onOpenFolder = onOpenFolder,
                )
            }
        }
    }
    if (detailsVisible) {
        C04CadDetailsSheet(
            visible = true,
            state = current,
            onDismiss = { detailsVisible = false },
        )
    }
}

@Composable
private fun C04CadViewerSurface(controller: C04CadViewerController, requestToken: Long) {
    AndroidView(
        modifier = Modifier.fillMaxSize().testTag("workspace.cadViewer"),
        factory = { context ->
            WebView(context).apply {
                // Compose's measured bounds alone do not clear WebView's
                // WRAP_CONTENT mode, which collapses percentage-height HTML.
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            }.also { controller.attachSurface(it, requestToken) }
        },
        update = { view -> controller.attachSurface(view, requestToken) },
        onRelease = { view -> controller.detachSurface(view) },
    )
}

@Composable
private fun BoxScope.LoadingOverlay(text: String) {
    Column(
        modifier = Modifier
            .align(Alignment.Center)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        FloeActivityIndicator(description = text)
        FloeText(text, style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
    }
}

@Composable
private fun SceneChip(
    state: C04CadViewerState.Ready,
    modifier: Modifier = Modifier,
) {
    // Compact summary chip: format · element/triangle count · localized
    // units only. The exact floating-point bounds moved into the existing
    // details sheet (they never fit this width honestly); numeric values
    // and units are never rounded or fabricated here.
    Column(
        modifier = modifier
            .widthIn(max = 360.dp)
            .background(Floe.colors.chromeSurface.copy(alpha = 0.94f), RoundedCornerShape(14.dp))
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(14.dp))
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        FloeText(
            sceneGeometry(state),
            style = Floe.typography.metadata,
            color = Floe.colors.label,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (state.missingResources.isNotEmpty()) {
            FloeStatusLine(
                icon = FloeIcons.WarningTriangle,
                text = stringResource(
                    R.string.workspace_document_cad_missing,
                    state.missingResources.size,
                ),
                color = Floe.colors.pending,
            )
        }
    }
}

@Composable
private fun SceneControls(
    controller: C04CadViewerController,
    state: C04CadViewerState.Ready,
    onSaveToFiles: () -> Unit,
    onDetails: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.widthIn(max = 560.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        FloeText(
            stringResource(
                if (state.format.family == C04CadFamily.VECTOR_2D) {
                    R.string.workspace_document_cad_hint_2d
                } else {
                    R.string.workspace_document_cad_hint_3d
                },
            ),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        val exportText = when {
            state.capturing -> stringResource(R.string.workspace_document_cad_capturing)
            state.exporting -> stringResource(R.string.workspace_document_cad_exporting)
            state.exportFailure != null -> stringResource(
                R.string.workspace_document_cad_export_failed)
            state.lastExport != null -> stringResource(
                R.string.workspace_document_cad_saved,
                state.lastExport.displayName,
                state.lastExport.pixelWidth,
                state.lastExport.pixelHeight,
            )
            state.captureFailure != null -> stringResource(
                R.string.workspace_document_cad_capture_failed)
            state.lastCapture != null -> stringResource(
                R.string.workspace_document_cad_captured_not_exported)
            else -> null
        }
        if (exportText != null) {
            val exported = state.lastExport != null &&
                state.exportFailure == null && !state.exporting
            FloeStatusLine(
                icon = if (exported) FloeIcons.CheckCircle else FloeIcons.WarningTriangle,
                text = exportText,
                color = if (exported) Floe.colors.success else Floe.colors.pending,
            )
        }
        // Toolbar. At sufficient width every action stays visible as a circle
        // or capsule (no scrolling strip). On narrower windows the same real
        // commands collapse to compact glyph buttons plus a "…" overflow, so
        // Save and every camera action remain reachable without a clipped
        // strip. The switch is a real measurement of the localized labels at
        // the current sp scale — never a fixed width guess. Camera gestures
        // on the surface are untouched.
        var overflowExpanded by rememberSaveable { mutableStateOf(false) }
        val is3d = state.format.family != C04CadFamily.VECTOR_2D
        val saveLabel = when {
            state.capturing -> stringResource(R.string.workspace_document_cad_capturing)
            state.exporting -> stringResource(R.string.workspace_document_cad_exporting)
            else -> stringResource(R.string.workspace_document_cad_save_preview)
        }
        val detailsLabel = stringResource(R.string.workspace_document_cad_details)
        BoxWithConstraints {
            val density = LocalDensity.current
            val textMeasurer = rememberTextMeasurer()
            val circleCount = (if (is3d) 6 else 4)
            // Exact worst-case width of the full strip: 48dp targets, 2dp
            // gaps, the two capsules at their measured label width plus the
            // shared capsule's 18dp side padding, and a 2dp hairline buffer.
            val fullWidth = with(density) {
                val gap = 2.dp.roundToPx()
                val capsuleSidePadding = 36.dp.roundToPx()
                val saveWidth = textMeasurer.measure(
                    saveLabel, Floe.typography.bodyEmphasized,
                ).size.width + capsuleSidePadding
                val detailsWidth = textMeasurer.measure(
                    detailsLabel, Floe.typography.bodyEmphasized,
                ).size.width + capsuleSidePadding
                (12.dp.roundToPx() +
                    circleCount * 48.dp.roundToPx() +
                    (circleCount + 1) * gap +
                    saveWidth + detailsWidth + 2.dp.roundToPx()).toDp()
            }
            val fullToolbar = fullWidth <= maxWidth
            val toolbarSurface = Modifier
                .background(
                    Floe.colors.chromeSurface.copy(alpha = 0.94f),
                    RoundedCornerShape(24.dp),
                )
                .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(24.dp))
                .padding(horizontal = 6.dp, vertical = 4.dp)
            if (fullToolbar) {
                Row(
                    modifier = toolbarSurface,
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    if (is3d) {
                        FloeCircleButton(
                            icon = FloeIcons.ChevronBack,
                            contentDescription = stringResource(R.string.workspace_document_cad_orbit_left),
                            onClick = { controller.command("orbitLeft") },
                            visualSize = 34.dp,
                            iconSize = 15.dp,
                        )
                        FloeCircleButton(
                            icon = FloeIcons.ChevronForward,
                            contentDescription = stringResource(R.string.workspace_document_cad_orbit_right),
                            onClick = { controller.command("orbitRight") },
                            visualSize = 34.dp,
                            iconSize = 15.dp,
                        )
                    }
                    FloeCircleButton(
                        icon = MinusIcon,
                        contentDescription = stringResource(R.string.workspace_document_cad_zoom_out),
                        onClick = { controller.command("zoomOut") },
                        visualSize = 34.dp,
                        iconSize = 15.dp,
                    )
                    FloeCircleButton(
                        icon = FloeIcons.Plus,
                        contentDescription = stringResource(R.string.workspace_document_cad_zoom_in),
                        onClick = { controller.command("zoomIn") },
                        visualSize = 34.dp,
                        iconSize = 15.dp,
                    )
                    FloeCircleButton(
                        icon = FitIcon,
                        contentDescription = stringResource(R.string.workspace_document_cad_fit),
                        onClick = { controller.command("fit") },
                        visualSize = 34.dp,
                        iconSize = 15.dp,
                    )
                    FloeCircleButton(
                        icon = FloeIcons.Refresh,
                        contentDescription = stringResource(R.string.workspace_document_cad_reset),
                        onClick = { controller.command("reset") },
                        visualSize = 34.dp,
                        iconSize = 15.dp,
                    )
                    FloeCapsuleAction(
                        label = saveLabel,
                        onClick = onSaveToFiles,
                        enabled = !state.capturing && !state.exporting,
                    )
                    FloeCapsuleAction(
                        label = detailsLabel,
                        onClick = onDetails,
                    )
                }
            } else {
                Box {
                    Row(
                        modifier = toolbarSurface,
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        FloeToolbarIconButton(
                            icon = MinusIcon,
                            contentDescription = stringResource(R.string.workspace_document_cad_zoom_out),
                            onClick = { controller.command("zoomOut") },
                        )
                        FloeToolbarIconButton(
                            icon = FloeIcons.Plus,
                            contentDescription = stringResource(R.string.workspace_document_cad_zoom_in),
                            onClick = { controller.command("zoomIn") },
                        )
                        FloeToolbarIconButton(
                            icon = FitIcon,
                            contentDescription = stringResource(R.string.workspace_document_cad_fit),
                            onClick = { controller.command("fit") },
                        )
                        FloeToolbarIconButton(
                            icon = FloeIcons.Refresh,
                            contentDescription = stringResource(R.string.workspace_document_cad_reset),
                            onClick = { controller.command("reset") },
                        )
                        FloeToolbarIconButton(
                            icon = SavePreviewIcon,
                            contentDescription = stringResource(R.string.workspace_document_cad_save_preview),
                            onClick = onSaveToFiles,
                            enabled = !state.capturing && !state.exporting,
                        )
                        FloeToolbarIconButton(
                            icon = FloeIcons.Ellipsis,
                            contentDescription = stringResource(R.string.workspace_document_cad_more_actions),
                            onClick = { overflowExpanded = true },
                        )
                    }
                    // Same opaque card + hairline chrome as the design-system
                    // choice menus; orbit/details stay one tap away.
                    FloeActionMenu(
                        expanded = overflowExpanded,
                        onDismissRequest = { overflowExpanded = false },
                        items = buildList {
                            if (is3d) {
                                add(
                                    FloeActionMenuItem(
                                        label = stringResource(R.string.workspace_document_cad_orbit_left),
                                        icon = FloeIcons.ChevronBack,
                                        onClick = { controller.command("orbitLeft") },
                                    )
                                )
                                add(
                                    FloeActionMenuItem(
                                        label = stringResource(R.string.workspace_document_cad_orbit_right),
                                        icon = FloeIcons.ChevronForward,
                                        onClick = { controller.command("orbitRight") },
                                    )
                                )
                            }
                            add(
                                FloeActionMenuItem(
                                    label = stringResource(R.string.workspace_document_cad_details),
                                    icon = FloeIcons.InfoCircle,
                                    onClick = onDetails,
                                )
                            )
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun FailureOverlay(
    state: C04CadViewerState.Failed,
    onRetry: () -> Unit,
    onDetails: () -> Unit,
    onOpenFolder: (() -> Unit)?,
) {
    val bodyRes = when (state.failure) {
        C04CadFailure.OWNER -> R.string.workspace_document_cad_failed_owner
        C04CadFailure.SOURCE -> R.string.workspace_document_cad_failed_source
        C04CadFailure.TOO_LARGE -> R.string.workspace_document_cad_failed_too_large
        C04CadFailure.INVALID -> R.string.workspace_document_cad_failed_invalid
        C04CadFailure.UNSUPPORTED -> when {
            state.format == C04CadFormat.FLOECAD && state.detail == "brepOnly" ->
                R.string.workspace_document_cad_brep_only
            state.format == C04CadFormat.FLOECAD ->
                R.string.workspace_document_cad_failed_invalid
            else -> R.string.workspace_document_cad_failed_unsupported
        }
        C04CadFailure.RESOURCE -> R.string.workspace_document_cad_failed_resource
        C04CadFailure.TRANSPORT -> R.string.workspace_document_cad_failed_transport
        C04CadFailure.RENDER -> R.string.workspace_document_cad_failed_render
        C04CadFailure.CAPTURE -> R.string.workspace_document_cad_failed_capture
        C04CadFailure.CORE_UPDATE -> R.string.workspace_document_cad_failed_core_update
        C04CadFailure.CANCELLED -> R.string.workspace_document_cad_failed_transport
    }
    Box(
        Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface)
            .testTag("workspace.cadFailure"),
    ) {
        FloeUnavailableView(
            icon = FloeIcons.WarningTriangle,
            title = stringResource(R.string.workspace_document_cad_failed_title),
            description = stringResource(bodyRes),
            action = {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (state.retryable) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.workspace_document_cad_retry),
                            onClick = onRetry,
                            modifier = Modifier.testTag("workspace.cadRetry"),
                        )
                    }
                    FloeCapsuleAction(
                        label = stringResource(R.string.workspace_document_cad_details),
                        onClick = onDetails,
                        modifier = Modifier.testTag("workspace.cadDetails"),
                    )
                    if (onOpenFolder != null && state.format == C04CadFormat.FLOECAD &&
                        (state.failure == C04CadFailure.INVALID ||
                            state.failure == C04CadFailure.UNSUPPORTED)
                    ) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.workspace_document_cad_open_folder),
                            onClick = onOpenFolder,
                            modifier = Modifier.testTag("workspace.cadOpenFolder"),
                        )
                    }
                }
            },
        )
    }
}

@Composable
private fun C04CadDetailsSheet(
    visible: Boolean,
    state: C04CadViewerState?,
    onDismiss: () -> Unit,
) {
    val width = LocalConfiguration.current.screenWidthDp
    val helper = if (width >= 700) 0.62f else 0.94f
    FloePageSheet(
        visible = visible,
        onDismiss = onDismiss,
        placement = FloeSheetPlacement.CENTER,
        widthFraction = helper,
        heightFraction = 0.68f,
    ) {
        Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
            FloeToolbar(
                title = stringResource(R.string.workspace_document_cad_details_title),
                navigation = {
                    FloeCapsuleAction(
                        label = stringResource(R.string.workspace_document_cad_details_done),
                        onClick = onDismiss,
                    )
                },
            )
            FloeDivider()
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (state) {
                    is C04CadViewerState.Ready -> {
                        val facts = state.facts
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_format), state.format.label)
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_reader), state.format.reader)
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_geometry), sceneGeometry(state))
                        DetailRow(
                            stringResource(R.string.workspace_document_cad_detail_units),
                            stringResource(
                                R.string.workspace_document_cad_units_detail,
                                unitsLabel(facts.sourceUnits),
                                unitsLabel(facts.displayUnits),
                            ),
                        )
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_bounds), boundsText(facts.bounds))
                        if (state.missingResources.isNotEmpty()) {
                            DetailRow(
                                stringResource(R.string.workspace_document_cad_missing_list),
                                state.missingResources.joinToString(", "),
                            )
                        }
                        if (facts.limitations.isNotBlank()) {
                            DetailRow(
                                stringResource(R.string.workspace_document_cad_limitations),
                                facts.limitations,
                            )
                        }
                        state.lastExport?.let {
                            DetailRow(
                                stringResource(R.string.workspace_document_cad_detail_export),
                                "${it.displayName} · ${it.pixelWidth}×${it.pixelHeight} · ${it.sha256.take(12)}",
                            )
                        }
                        state.lastCapture?.let {
                            DetailRow(
                                stringResource(R.string.workspace_document_cad_detail_capture),
                                "${it.pixelWidth}×${it.pixelHeight} · ${it.sha256.take(12)}",
                            )
                        }
                    }
                    is C04CadViewerState.Failed -> {
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_failure), state.failure.name)
                        state.format?.let { DetailRow(stringResource(R.string.workspace_document_cad_detail_format), it.label) }
                        state.detail?.let { DetailRow(stringResource(R.string.workspace_document_cad_detail_diagnostic), it) }
                    }
                    is C04CadViewerState.Rendering -> {
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_format), state.format.label)
                        DetailRow(stringResource(R.string.workspace_document_cad_detail_reader), state.format.reader)
                        DetailRow(
                            stringResource(R.string.workspace_document_cad_detail_state),
                            stringResource(R.string.workspace_document_cad_rendering),
                        )
                    }
                    is C04CadViewerState.Opening -> DetailRow(
                        stringResource(R.string.workspace_document_cad_detail_state),
                        stringResource(R.string.workspace_document_cad_preparing),
                    )
                    C04CadViewerState.Idle, null -> DetailRow(
                        stringResource(R.string.workspace_document_cad_detail_state),
                        "—",
                    )
                }
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        FloeText(
            label,
            modifier = Modifier.widthIn(min = 84.dp),
            style = Floe.typography.metadata,
            color = Floe.colors.secondaryLabel,
        )
        FloeText(
            value,
            modifier = Modifier.weight(1f),
            style = Floe.typography.metadata,
            color = Floe.colors.label,
        )
    }
}

@Composable
private fun sceneGeometry(state: C04CadViewerState.Ready): String {
    val facts = state.facts
    val units = if (facts.sourceUnits == facts.displayUnits) {
        unitsLabel(facts.sourceUnits)
    } else {
        "${unitsLabel(facts.sourceUnits)} (display ${unitsLabel(facts.displayUnits)})"
    }
    val count = facts.entityCount
    return if (count != null) {
        stringResource(
            R.string.workspace_document_cad_scene_2d,
            state.format.label,
            NumberFormat.getIntegerInstance(Locale.getDefault()).format(count),
            units,
        )
    } else {
        stringResource(
            R.string.workspace_document_cad_scene_3d,
            state.format.label,
            NumberFormat.getIntegerInstance(Locale.getDefault()).format(facts.triangleCount),
            units,
        )
    }
}

/**
 * Localized unit label. Unitless sources (the controller's "unknown") read
 * as "Not specified"/未指定 — never a fabricated "mm" — while real units
 * (mm/cm/m/in/ft/yd) pass through exactly.
 */
@Composable
private fun unitsLabel(units: String): String = when (units) {
    "unknown", "" -> stringResource(R.string.workspace_document_cad_units_unspecified)
    else -> units
}

private fun boundsText(bounds: C04CadBounds): String {
    val minimum = bounds.minimum
    val maximum = bounds.maximum
    if (minimum != null && maximum != null && minimum.size == 3 && maximum.size == 3) {
        return "${vectorText(minimum)} – ${vectorText(maximum)}"
    }
    val center = bounds.center
    if (center != null && center.size == 3) {
        return "${vectorText(center)} · r ${formatNumber(bounds.radius ?: 0.0)}"
    }
    return "—"
}

private fun vectorText(values: List<Double>): String =
    values.joinToString(", ") { formatNumber(it) }

private fun formatNumber(value: Double): String {
    if (!value.isFinite()) return "—"
    if (abs(value) >= 1_000_000 || (value != 0.0 && abs(value) < 0.0001)) {
        return String.format(Locale.US, "%.4g", value)
    }
    return String.format(Locale.US, "%.4f", value).trimEnd('0').trimEnd('.')
}

private fun cadCaptureName(fileName: String): String {
    val base = fileName.substringBeforeLast('.')
        .replace(Regex("[\\\\/:*?\"<>|]"), "_")
        .take(60)
        .ifBlank { "drawing" }
    return "$base-preview.png"
}

private fun cadIcon(name: String, block: ImageVector.Builder.() -> Unit): ImageVector =
    ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    ).apply(block).build()

private fun ImageVector.Builder.stroke(pathData: PathBuilder.() -> Unit) {
    path(
        fill = null,
        stroke = SolidColor(Color.Black),
        strokeLineWidth = 1.8f,
        strokeLineCap = StrokeCap.Round,
        strokeLineJoin = StrokeJoin.Round,
        pathFillType = PathFillType.NonZero,
        pathBuilder = { pathData() },
    )
}

private val MinusIcon: ImageVector = cadIcon("floe.cad.minus") {
    stroke {
        moveTo(5f, 12f)
        lineTo(19f, 12f)
    }
}

/** iOS square.and.arrow.down — compact Save-to-Files toolbar glyph. */
private val SavePreviewIcon: ImageVector = cadIcon("floe.cad.save_preview") {
    stroke {
        moveTo(12f, 3f)
        lineTo(12f, 13f)
    }
    stroke {
        moveTo(7.5f, 9.5f)
        lineTo(12f, 14f)
        lineTo(16.5f, 9.5f)
    }
    stroke {
        moveTo(5f, 16.5f)
        lineTo(5f, 19f)
        lineTo(19f, 19f)
        lineTo(19f, 16.5f)
    }
}

private val FitIcon: ImageVector = cadIcon("floe.cad.fit") {
    stroke { moveTo(4f, 9f); lineTo(4f, 4f); lineTo(9f, 4f) }
    stroke { moveTo(15f, 4f); lineTo(20f, 4f); lineTo(20f, 9f) }
    stroke { moveTo(20f, 15f); lineTo(20f, 20f); lineTo(15f, 20f) }
    stroke { moveTo(9f, 20f); lineTo(4f, 20f); lineTo(4f, 15f) }
}
