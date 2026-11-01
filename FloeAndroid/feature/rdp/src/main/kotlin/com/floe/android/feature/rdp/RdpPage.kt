// SPDX-License-Identifier: MPL-2.0
//
// Full-screen RDP viewer and RDP endpoint management. Presentation only: the
// App-owned controller owns the real FreeRDP session, frame lease, input lane,
// certificate decision and credential gateway. This page computes the
// fit/zoom/pan mapping, forwards pointer/keyboard/wheel input and releases
// pressed input when the view leaves the foreground or the composition.

package com.floe.android.feature.rdp

import android.view.KeyEvent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.nativeKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeConfirmDialog
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloePlainFormField
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import kotlin.math.abs
import kotlin.math.roundToInt

@Composable
public fun RdpDestinationUi(
    state: RdpUiState,
    actions: RdpActions,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    val session = state.session
    if (session != null) {
        RdpViewerPage(
            session = session,
            error = state.error,
            actions = actions,
            compact = compact,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
            showSidebarToggle = showSidebarToggle,
        )
    } else {
        RdpHostsPage(
            state = state,
            actions = actions,
            compact = compact,
            showSidebarToggle = showSidebarToggle,
            onExpandSidebar = onExpandSidebar,
            onOpenDrawer = onOpenDrawer,
        )
    }
    state.prompt?.let { prompt ->
        RdpTrustSheet(prompt = prompt, actions = actions)
    }
}

@Composable
private fun RdpHostsPage(
    state: RdpUiState,
    actions: RdpActions,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    var editorVisible by rememberSaveable { mutableStateOf(false) }
    var draft by remember { mutableStateOf(RdpProfileDraftUi()) }
    var pendingDelete by remember { mutableStateOf<RdpHostDetailUi?>(null) }

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = stringResource(R.string.rdp_title),
            navigation = {
                if (compact || showSidebarToggle) {
                    FloeCircleButton(
                        icon = FloeIcons.SidebarToggle,
                        contentDescription = stringResource(R.string.rdp_title),
                        onClick = if (compact) onOpenDrawer else onExpandSidebar,
                    )
                }
            },
            actions = {
                if (state.busy != null) {
                    FloeActivityIndicator()
                    Spacer(Modifier.width(6.dp))
                }
                FloeCircleButton(
                    icon = FloeIcons.Plus,
                    contentDescription = stringResource(R.string.rdp_add),
                    onClick = {
                        draft = RdpProfileDraftUi(endpoints = listOf(RdpEndpointDraftUi()))
                        editorVisible = true
                    },
                )
                FloeCircleButton(
                    icon = FloeIcons.Refresh,
                    contentDescription = stringResource(R.string.rdp_refresh),
                    onClick = actions.onRefresh,
                )
            },
            showHairline = true,
        )

        state.error?.let { error ->
            RdpErrorBanner(error, actions.onDismissError)
        }

        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                FloeActivityIndicator(description = stringResource(R.string.rdp_loading))
            }
            !state.coreReady -> FloeUnavailableView(
                icon = FloeIcons.DeviceLocal,
                title = stringResource(R.string.rdp_title),
                description = stringResource(R.string.rdp_unavailable),
                action = null,
            )
            state.hosts.isEmpty() -> FloeUnavailableView(
                icon = FloeIcons.DeviceLocal,
                title = stringResource(R.string.rdp_empty_title),
                description = stringResource(R.string.rdp_empty_hint),
                action = null,
            )
            else -> Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                state.hosts.forEach { host ->
                    RdpHostCard(
                        host = host,
                        busy = state.busy,
                        onConnect = { endpoint -> actions.onConnect(host.id, endpoint.id) },
                        onEdit = { endpoint ->
                            draft = RdpProfileDraftUi(
                                id = host.id,
                                displayName = host.displayName,
                                deviceKind = host.deviceKind,
                                endpoints = listOf(
                                    RdpEndpointDraftUi(
                                        id = endpoint.id,
                                        displayName = endpoint.displayName,
                                        host = endpoint.host,
                                        port = endpoint.port.toString(),
                                        username = endpoint.username,
                                        domain = endpoint.domain,
                                        keepPassword = endpoint.hasPassword,
                                    )
                                ),
                            )
                            editorVisible = true
                        },
                        onDeleteEndpoint = { endpoint ->
                            actions.onDeleteEndpoint(host.id, endpoint.id)
                        },
                        onDeleteHost = { pendingDelete = host },
                    )
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }

    if (editorVisible) {
        RdpEditorSheet(
            draft = draft,
            onDraftChange = { draft = it },
            onSave = {
                editorVisible = false
                actions.onSave(draft)
            },
            onDismiss = { editorVisible = false },
        )
    }

    pendingDelete?.let { host ->
        FloeConfirmDialog(
            title = stringResource(R.string.rdp_delete_host_title),
            message = stringResource(R.string.rdp_delete_host_message),
            confirmLabel = stringResource(R.string.rdp_delete),
            dismissLabel = stringResource(R.string.rdp_cancel),
            onConfirm = {
                pendingDelete = null
                actions.onDeleteHost(host.id)
            },
            onDismiss = { pendingDelete = null },
        )
    }
}

@Composable
private fun RdpHostCard(
    host: RdpHostDetailUi,
    busy: String?,
    onConnect: (RdpEndpointUi) -> Unit,
    onEdit: (RdpEndpointUi) -> Unit,
    onDeleteEndpoint: (RdpEndpointUi) -> Unit,
    onDeleteHost: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Floe.colors.chromeSurface)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                host.displayName,
                style = Floe.typography.section,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
            )
            FloeCapsuleAction(
                label = stringResource(R.string.rdp_delete),
                onClick = onDeleteHost,
                showHairline = false,
                tint = Floe.colors.destructive,
            )
        }
        if (host.endpoints.isEmpty()) {
            FloeText(
                stringResource(R.string.rdp_empty_hint),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }
        host.endpoints.forEach { endpoint ->
            Column(
                Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(Floe.colors.readingSurface)
                    .clickable(enabled = busy == null) { onConnect(endpoint) }
                    .padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    FloeText(
                        endpoint.displayName,
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                        modifier = Modifier.weight(1f),
                    )
                    FloeBadgePill(
                        text = stringResource(
                            if (endpoint.trusted) R.string.rdp_trusted else R.string.rdp_untrusted
                        ),
                        tone = if (endpoint.trusted) FloeBadgeTone.SUCCESS else FloeBadgeTone.PENDING,
                    )
                }
                FloeText(
                    "${endpoint.target} · ${endpoint.username}" +
                        (if (endpoint.domain.isBlank()) "" else " · ${endpoint.domain}"),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FloeCapsuleAction(
                        label = stringResource(R.string.rdp_connect),
                        onClick = { onConnect(endpoint) },
                        enabled = busy == null,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.rdp_edit),
                        onClick = { onEdit(endpoint) },
                        showHairline = false,
                        enabled = busy == null,
                    )
                    FloeCapsuleAction(
                        label = stringResource(R.string.rdp_delete),
                        onClick = { onDeleteEndpoint(endpoint) },
                        showHairline = false,
                        tint = Floe.colors.destructive,
                        enabled = busy == null && host.endpoints.size > 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun RdpEditorSheet(
    draft: RdpProfileDraftUi,
    onDraftChange: (RdpProfileDraftUi) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
) {
    val endpoint = draft.endpoints.firstOrNull() ?: RdpEndpointDraftUi()
    fun updateEndpoint(transform: (RdpEndpointDraftUi) -> RdpEndpointDraftUi) {
        onDraftChange(draft.copy(endpoints = listOf(transform(endpoint))))
    }
    val port = endpoint.port.toIntOrNull()
    val valid = draft.displayName.isNotBlank() &&
        endpoint.host.isNotBlank() && endpoint.username.isNotBlank() &&
        port != null && port in 1..65535 &&
        (endpoint.password.isNotEmpty() || endpoint.keepPassword)

    FloePageSheet(
        visible = true,
        onDismiss = onDismiss,
        widthFraction = 0.68f,
        heightFraction = 0.86f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(Modifier.fillMaxSize().padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_cancel),
                    onClick = onDismiss,
                    showHairline = false,
                )
                Spacer(Modifier.weight(1f))
                FloeText(
                    if (draft.id == null) stringResource(R.string.rdp_add) else stringResource(R.string.rdp_edit),
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_save),
                    onClick = onSave,
                    enabled = valid,
                )
            }
            FloeDivider(Modifier.padding(vertical = 8.dp))
            Column(
                Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                FloeText(stringResource(R.string.rdp_display_name), style = Floe.typography.metadata)
                FloePlainFormField(
                    label = stringResource(R.string.rdp_display_name),
                    value = draft.displayName,
                    onValueChange = { onDraftChange(draft.copy(displayName = it)) },
                )
                FloeText(stringResource(R.string.rdp_host), style = Floe.typography.metadata)
                FloePlainFormField(
                    label = stringResource(R.string.rdp_host),
                    value = endpoint.host,
                    onValueChange = { value -> updateEndpoint { it.copy(host = value) } },
                )
                FloeText(stringResource(R.string.rdp_port), style = Floe.typography.metadata)
                FloePlainFormField(
                    label = stringResource(R.string.rdp_port),
                    value = endpoint.port,
                    onValueChange = { value -> updateEndpoint { it.copy(port = value) } },
                    keyboardOptions = KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                )
                FloeText(stringResource(R.string.rdp_username), style = Floe.typography.metadata)
                FloePlainFormField(
                    label = stringResource(R.string.rdp_username),
                    value = endpoint.username,
                    onValueChange = { value -> updateEndpoint { it.copy(username = value) } },
                )
                FloeText(stringResource(R.string.rdp_domain), style = Floe.typography.metadata)
                FloePlainFormField(
                    label = stringResource(R.string.rdp_domain),
                    value = endpoint.domain,
                    onValueChange = { value -> updateEndpoint { it.copy(domain = value) } },
                )
                FloeText(stringResource(R.string.rdp_password), style = Floe.typography.metadata)
                FloePlainFormField(
                    label = stringResource(R.string.rdp_password),
                    value = endpoint.password,
                    onValueChange = { value -> updateEndpoint { it.copy(password = value) } },
                    keyboardOptions = KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Password),
                )
                if (endpoint.keepPassword) {
                    FloeText(
                        stringResource(R.string.rdp_password_keep),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }
        }
    }
}

@Composable
private fun RdpTrustSheet(prompt: RdpCertificatePromptUi, actions: RdpActions) {
    FloePageSheet(
        visible = true,
        onDismiss = actions.onRejectTrust,
        widthFraction = 0.72f,
        heightFraction = 0.72f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        Column(
            Modifier.fillMaxSize().padding(20.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FloeText(
                stringResource(R.string.rdp_trust_title),
                style = Floe.typography.section,
                color = Floe.colors.label,
            )
            FloeText(
                stringResource(R.string.rdp_trust_message),
                style = Floe.typography.body,
                color = Floe.colors.secondaryLabel,
            )
            FloeText(
                "${prompt.host}:${prompt.port}",
                style = Floe.typography.body,
                color = Floe.colors.label,
            )
            FloeText(
                "${stringResource(R.string.rdp_subject)}: ${prompt.subject}",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            FloeText(
                "${stringResource(R.string.rdp_fingerprint)}: ${prompt.fingerprintSHA256}",
                style = Floe.typography.metadata,
                color = Floe.colors.label,
            )
            prompt.notAfter?.let {
                FloeText("Valid until: $it", style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_reject),
                    onClick = actions.onRejectTrust,
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_trust),
                    onClick = actions.onTrust,
                )
            }
        }
    }
}

@Composable
private fun RdpViewerPage(
    session: RdpSessionUi,
    error: RdpFailureUi?,
    actions: RdpActions,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
) {
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var zoom by remember(session.sessionID) { mutableFloatStateOf(1f) }
    var panX by remember(session.sessionID) { mutableFloatStateOf(0f) }
    var panY by remember(session.sessionID) { mutableFloatStateOf(0f) }
    var keyboardVisible by remember(session.sessionID) { mutableStateOf(false) }
    var modifiers by remember(session.sessionID) { mutableStateOf(emptySet<String>()) }
    var textField by remember(session.sessionID) { mutableStateOf(TextFieldValue("")) }
    var lastSent by remember(session.sessionID) { mutableStateOf("") }
    val transform = rdpTransform(
        viewWidth = viewSize.width.toFloat(),
        viewHeight = viewSize.height.toFloat(),
        frameWidth = session.width,
        frameHeight = session.height,
        zoom = zoom,
        panX = panX,
        panY = panY,
    )
    val currentTransform by rememberUpdatedState(transform)
    val imageBitmap = remember(session.revision, session.bitmap) { session.bitmap?.asImageBitmap() }

    LaunchedEffect(keyboardVisible) {
        if (!keyboardVisible) {
            modifiers.forEach { modifier ->
                actions.onModifier(
                    when (modifier) {
                        "ctrl" -> "control"
                        "win" -> "meta"
                        else -> modifier
                    },
                    false,
                )
            }
            modifiers = emptySet()
        }
    }

    val lifecycleOwner = LocalContext.current as? androidx.lifecycle.LifecycleOwner
    DisposableEffect(lifecycleOwner, session.sessionID) {
        val owner = lifecycleOwner
        if (owner == null) {
            onDispose {
                actions.onReleaseAll()
                actions.onVisible(false)
            }
        } else {
            val observer = LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_START -> actions.onVisible(true)
                    Lifecycle.Event.ON_STOP -> {
                        actions.onReleaseAll()
                        actions.onVisible(false)
                    }
                    else -> Unit
                }
            }
            owner.lifecycle.addObserver(observer)
            onDispose {
                actions.onReleaseAll()
                actions.onVisible(false)
                owner.lifecycle.removeObserver(observer)
            }
        }
    }

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = session.displayName,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.rdp_close_session),
                    onClick = actions.onDisconnect,
                )
            },
            actions = {
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_fit),
                    onClick = { zoom = 1f; panX = 0f; panY = 0f },
                    showHairline = false,
                )
                FloeCapsuleAction(label = "−", onClick = { zoom = rdpClampZoom(zoom, 0.8f) }, showHairline = false)
                FloeCapsuleAction(label = "+", onClick = { zoom = rdpClampZoom(zoom, 1.25f) }, showHairline = false)
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_reconnect),
                    onClick = actions.onReconnect,
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_reset),
                    onClick = actions.onReset,
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_keyboard),
                    onClick = { keyboardVisible = !keyboardVisible },
                    tint = if (keyboardVisible) Floe.colors.accent else Floe.colors.label,
                )
            },
            showHairline = true,
        )

        val currentError = error ?: session.failure
        currentError?.let { failure ->
            RdpErrorBanner(failure, actions.onDismissError)
        }

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeBadgePill(
                text = rdpStateLabel(session.state),
                tone = when (session.state) {
                    "connected" -> FloeBadgeTone.SUCCESS
                    "failed" -> FloeBadgeTone.PENDING
                    else -> FloeBadgeTone.SECONDARY
                },
            )
            Spacer(Modifier.width(8.dp))
            FloeText(
                "${session.host}:${session.port} · ${session.username}" +
                    (if (session.domain.isBlank()) "" else " · ${session.domain}"),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeText(
                if (session.width > 0) "${session.width}×${session.height}" else "—",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
            session.inputIssue?.let {
                Spacer(Modifier.width(8.dp))
                FloeText(it, style = Floe.typography.metadata, color = Floe.colors.destructive)
            }
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .background(androidx.compose.ui.graphics.Color.Black)
                .onSizeChanged { viewSize = it }
                .pointerInput(session.sessionID, session.width, session.height) {
                    detectTapGestures(
                        onTap = { point ->
                            rdpMapPoint(currentTransform, point.x, point.y)?.let { (x, y) ->
                                actions.onPointerButton("left", true, x, y)
                                actions.onPointerButton("left", false, x, y)
                            }
                        },
                        onLongPress = { point ->
                            rdpMapPoint(currentTransform, point.x, point.y)?.let { (x, y) ->
                                actions.onPointerButton("right", true, x, y)
                                actions.onPointerButton("right", false, x, y)
                            }
                        },
                    )
                }
                .pointerInput(session.sessionID) {
                    var lastPoint: Pair<Int, Int>? = null
                    detectDragGestures(
                        onDragStart = { point ->
                            lastPoint = rdpMapPoint(currentTransform, point.x, point.y)
                            lastPoint?.let { (x, y) -> actions.onPointerButton("left", true, x, y) }
                        },
                        onDragEnd = {
                            lastPoint?.let { (x, y) -> actions.onPointerButton("left", false, x, y) }
                            lastPoint = null
                        },
                        onDragCancel = {
                            lastPoint?.let { (x, y) -> actions.onPointerButton("left", false, x, y) }
                            lastPoint = null
                        },
                    ) { change, _ ->
                        rdpMapPoint(currentTransform, change.position.x, change.position.y)?.let { (x, y) ->
                            lastPoint = x to y
                            actions.onPointerMove(x, y)
                        }
                    }
                }
                .pointerInput(session.sessionID) {
                    detectTransformGestures { centroid, pan, gestureZoom, _ ->
                        if (zoom <= 1.001f && abs(gestureZoom - 1f) < 0.02f && abs(pan.y) >= 1f) {
                            rdpMapPoint(currentTransform, centroid.x, centroid.y)?.let { point ->
                                actions.onWheel(
                                    pan.y < 0f,
                                    minOf(20, maxOf(1, abs(pan.y).roundToInt())),
                                    point.first,
                                    point.second,
                                )
                            }
                        } else {
                            val nextZoom = rdpClampZoom(zoom, gestureZoom)
                            val (nextX, nextY) = rdpClampPan(
                                viewSize.width.toFloat(),
                                viewSize.height.toFloat(),
                                session.width,
                                session.height,
                                nextZoom,
                                panX + pan.x,
                                panY + pan.y,
                            )
                            zoom = nextZoom
                            panX = nextX
                            panY = nextY
                        }
                    }
                }
                .pointerInput(session.sessionID, session.width, session.height) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent()
                            if (event.type == PointerEventType.Scroll) {
                                val change = event.changes.firstOrNull() ?: continue
                                val delta = change.scrollDelta.y
                                if (abs(delta) < 0.01f) continue
                                rdpMapPoint(currentTransform, change.position.x, change.position.y)
                                    ?.let { point ->
                                        actions.onWheel(
                                            delta < 0f,
                                            minOf(20, maxOf(1, abs(delta).roundToInt())),
                                            point.first,
                                            point.second,
                                        )
                                    }
                                change.consume()
                            }
                        }
                    }
                }
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val image = imageBitmap
                if (image != null && transform.displayWidth > 0f) {
                    drawImage(
                        image = image,
                        srcOffset = androidx.compose.ui.unit.IntOffset.Zero,
                        srcSize = androidx.compose.ui.unit.IntSize(image.width, image.height),
                        dstOffset = androidx.compose.ui.unit.IntOffset(
                            transform.offsetX.roundToInt(),
                            transform.offsetY.roundToInt(),
                        ),
                        dstSize = androidx.compose.ui.unit.IntSize(
                            transform.displayWidth.roundToInt(),
                            transform.displayHeight.roundToInt(),
                        ),
                        filterQuality = FilterQuality.None,
                    )
                }
            }
            if (session.state != "connected" || session.bitmap == null) {
                Column(
                    Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    FloeActivityIndicator()
                    Spacer(Modifier.height(8.dp))
                    FloeText(
                        rdpStateLabel(session.state),
                        style = Floe.typography.metadata,
                        color = androidx.compose.ui.graphics.Color.White,
                    )
                }
            }
            Row(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(8.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                ModifierButton(
                    label = stringResource(R.string.rdp_shift),
                    active = "shift" in modifiers,
                ) { down ->
                    if (down) modifiers = modifiers + "shift" else modifiers = modifiers - "shift"
                    actions.onModifier("shift", down)
                }
                ModifierButton(
                    label = stringResource(R.string.rdp_ctrl),
                    active = "ctrl" in modifiers,
                ) { down ->
                    if (down) modifiers = modifiers + "ctrl" else modifiers = modifiers - "ctrl"
                    actions.onModifier("control", down)
                }
                ModifierButton(
                    label = stringResource(R.string.rdp_alt),
                    active = "alt" in modifiers,
                ) { down ->
                    if (down) modifiers = modifiers + "alt" else modifiers = modifiers - "alt"
                    actions.onModifier("alt", down)
                }
                ModifierButton(
                    label = stringResource(R.string.rdp_win),
                    active = "win" in modifiers,
                ) { down ->
                    if (down) modifiers = modifiers + "win" else modifiers = modifiers - "win"
                    actions.onModifier("meta", down)
                }
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    label = "Scroll ▲",
                    onClick = { actions.onWheel(true, 3, session.width / 2, session.height / 2) },
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = "Scroll ▼",
                    onClick = { actions.onWheel(false, 3, session.width / 2, session.height / 2) },
                    showHairline = false,
                )
            }
        }

        if (keyboardVisible) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicTextField(
                    value = textField,
                    onValueChange = { next ->
                        val previous = lastSent
                        val text = next.text
                        if (text.length > previous.length && text.startsWith(previous)) {
                            actions.onText(text.substring(previous.length))
                        } else if (text.length < previous.length && previous.startsWith(text)) {
                            repeat(previous.length - text.length) { actions.onNamedKey("Backspace") }
                        }
                        lastSent = text
                        textField = next
                    },
                    textStyle = Floe.typography.body.copy(color = Floe.colors.label),
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        imeAction = ImeAction.Send,
                    ),
                    keyboardActions = KeyboardActions(onSend = { actions.onSubmit() }),
                    modifier = Modifier.weight(1f)
                        .background(Floe.colors.chromeSurface)
                        .padding(horizontal = 10.dp, vertical = 8.dp)
                        .onPreviewKeyEvent { event ->
                            if (event.type == androidx.compose.ui.input.key.KeyEventType.KeyUp ||
                                event.type == androidx.compose.ui.input.key.KeyEventType.KeyDown
                            ) {
                                val native = event.nativeKeyEvent
                                val down = event.type == androidx.compose.ui.input.key.KeyEventType.KeyDown
                                val named = when (native.keyCode) {
                                    KeyEvent.KEYCODE_ENTER -> "Return"
                                    KeyEvent.KEYCODE_TAB -> "Tab"
                                    KeyEvent.KEYCODE_ESCAPE -> "Escape"
                                    KeyEvent.KEYCODE_DEL -> "Backspace"
                                    KeyEvent.KEYCODE_DPAD_LEFT -> "Left"
                                    KeyEvent.KEYCODE_DPAD_RIGHT -> "Right"
                                    KeyEvent.KEYCODE_DPAD_UP -> "Up"
                                    KeyEvent.KEYCODE_DPAD_DOWN -> "Down"
                                    else -> null
                                }
                                if (named != null && down) {
                                    actions.onNamedKey(named)
                                    true
                                } else {
                                    false
                                }
                            } else {
                                false
                            }
                        },
                )
                Spacer(Modifier.width(6.dp))
                FloeCapsuleAction(
                    label = stringResource(R.string.rdp_submit),
                    onClick = actions.onSubmit,
                    showHairline = false,
                )
            }
        }
    }
}

@Composable
private fun ModifierButton(
    label: String,
    active: Boolean,
    onToggle: (Boolean) -> Unit,
) {
    FloeCapsuleAction(
        label = label,
        onClick = { onToggle(!active) },
        showHairline = false,
        tint = if (active) Floe.colors.accent else Floe.colors.label,
    )
}

@Composable
private fun RdpErrorBanner(failure: RdpFailureUi, onDismiss: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .background(Floe.colors.destructive.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 16.dp)
        Spacer(Modifier.width(8.dp))
        val message = when (failure.code) {
            "runtimeUnavailable", "coreUnavailable", "runtimeNotReady" ->
                stringResource(R.string.rdp_runtime_unavailable)
            else -> failure.message.ifBlank { stringResource(R.string.rdp_error) }
        }
        FloeText(
            message,
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = stringResource(R.string.rdp_cancel),
            onClick = onDismiss,
            showHairline = false,
            tint = Floe.colors.destructive,
        )
    }
}

@Composable
private fun rdpStateLabel(state: String): String = when (state) {
    "connected" -> stringResource(R.string.rdp_state_connected)
    "connecting" -> stringResource(R.string.rdp_state_connecting)
    "closing" -> stringResource(R.string.rdp_state_closing)
    "failed" -> stringResource(R.string.rdp_state_failed)
    "disconnected", "closed" -> stringResource(R.string.rdp_state_disconnected)
    else -> state
}
