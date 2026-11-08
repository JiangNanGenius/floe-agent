// SPDX-License-Identifier: MPL-2.0
//
// Full-screen VNC viewer. Presentation only: the App controller owns the
// real RFB session, frame lease and input lane. This page computes the
// fit/zoom/pan mapping, sends pointer/key/wheel events and releases pressed
// input when the view leaves the foreground or composition.
//
// Chrome is a single compact control bar (close, short elided title,
// keyboard, viewer options, hide-controls). Connection details, zoom steps,
// the gesture help and caller-specific secondary actions live in the viewer
// options overlay; hiding the chrome leaves the desktop in the full area
// with one reachable handle that restores the controls. The special-key
// strip is one horizontally scrollable row above the text bridge.

package com.floe.android.feature.remote

import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.floe.android.design.Floe
import com.floe.android.design.FloeBadgePill
import com.floe.android.design.FloeBadgeTone
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeSegmented
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeToolbarIconButton
import com.floe.android.design.IconGlyph
import kotlin.math.abs
import kotlin.math.roundToInt

data class RemoteVncActions(
    val onConnect: (String, String?) -> Unit,
    val onClose: () -> Unit,
    val onVisible: (Boolean) -> Unit,
    val onPointerMove: (Int, Int) -> Unit,
    val onPointerButton: (String, Boolean, Int, Int) -> Unit,
    val onWheel: (String, Int, Int, Int) -> Unit,
    val onKey: (Long, Boolean) -> Unit,
    val onText: (String) -> Unit,
    val onReleaseAll: () -> Unit,
    val onSaveHost: (RemoteVncHostDraft) -> Unit,
    val onSaveEndpoint: (String, RemoteVncEndpointDraft) -> Unit,
    val onDeleteEndpoint: (String, String) -> Unit,
)

/**
 * Shared remote-desktop viewer. [title] and [closeLabel] let an embedding
 * host restyle the chrome without forking the renderer: the standalone VNC
 * host passes none (its close ends the owned session), while the Linux
 * desktop sheet passes the running application and a "close viewer" label
 * that only hides the session. [notice] renders a compact banner above the
 * viewport (save-pending / recovery states) and [infoActions] appends host
 * actions to the viewer-options overlay.
 */
@Composable
fun RemoteVncViewerPage(
    vnc: RemoteVncUi,
    error: RemoteHostUiError?,
    compact: Boolean,
    onClose: () -> Unit,
    onVisible: (Boolean) -> Unit,
    onPointerMove: (Int, Int) -> Unit,
    onPointerButton: (String, Boolean, Int, Int) -> Unit,
    onWheel: (String, Int, Int, Int) -> Unit,
    onKey: (Long, Boolean) -> Unit,
    onText: (String) -> Unit,
    onReleaseAll: () -> Unit,
    onDismissError: () -> Unit,
    title: String? = null,
    closeLabel: String? = null,
    notice: (@Composable () -> Unit)? = null,
    infoActions: (@Composable ColumnScope.() -> Unit)? = null,
) {
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var zoom by remember(vnc.sessionID) { mutableFloatStateOf(1f) }
    var panX by remember(vnc.sessionID) { mutableFloatStateOf(0f) }
    var panY by remember(vnc.sessionID) { mutableFloatStateOf(0f) }
    var keyboardVisible by remember(vnc.sessionID) { mutableStateOf(false) }
    var chromeHidden by remember(vnc.sessionID) { mutableStateOf(false) }
    var menuOpen by remember(vnc.sessionID) { mutableStateOf(false) }
    var modifiers by remember(vnc.sessionID) { mutableStateOf(emptySet<Long>()) }
    var textField by remember(vnc.sessionID) { mutableStateOf(TextFieldValue("")) }
    // The text bridge reports an initial unfocused state before the open
    // effect can request focus; only a real focus loss (previously focused)
    // may close the keyboard again.
    var textFieldFocused by remember(vnc.sessionID) { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val context = LocalContext.current
    val inputPreferences = remember(context) { RemoteVncInputPreferences(context) }
    var inputMode by remember(inputPreferences) { mutableStateOf(inputPreferences.load()) }
    val viewConfiguration = LocalViewConfiguration.current
    val pointer = remember(vnc.sessionID) {
        VncTouchPointer(vnc.width, vnc.height, inputMode,
            viewConfiguration.doubleTapTimeoutMillis, viewConfiguration.longPressTimeoutMillis,
            viewConfiguration.touchSlop)
    }
    var pointerPosition by remember(pointer) { mutableStateOf(pointer.position) }
    var inputForeground by remember(vnc.sessionID) { mutableStateOf(true) }

    val transform = vncTransform(
        viewWidth = viewSize.width.toFloat(),
        viewHeight = viewSize.height.toFloat(),
        frameWidth = vnc.width,
        frameHeight = vnc.height,
        zoom = zoom,
        panX = panX,
        panY = panY,
    )
    val imageBitmap = remember(vnc.revision, vnc.bitmap) { vnc.bitmap?.asImageBitmap() }
    val currentTransform by rememberUpdatedState(transform)

    fun applyPointer(actions: List<VncPointerAction>) {
        actions.forEach { action ->
            when (action) {
                is VncPointerAction.Move -> onPointerMove(action.x, action.y)
                is VncPointerAction.Button -> onPointerButton(action.button, action.down, action.x, action.y)
            }
        }
        pointerPosition = pointer.position
        if (inputMode == VncInputMode.TRACKPAD && actions.any { it is VncPointerAction.Move }) {
            val next = vncPanToPointer(currentTransform, pointer.position,
                viewSize.width.toFloat(), viewSize.height.toFloat(), zoom, panX, panY, 24f)
            panX = next.first
            panY = next.second
        }
    }
    fun releaseInput() {
        applyPointer(pointer.cancel())
        onReleaseAll()
        modifiers = emptySet()
    }
    LaunchedEffect(pointer, vnc.width, vnc.height) {
        applyPointer(pointer.resize(vnc.width, vnc.height))
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, vnc.sessionID) {
        val lifecycle = lifecycleOwner.lifecycle
        // Dialog contexts need not be LifecycleOwners. Re-entering the viewer
        // after its software picker must resume frame delivery immediately,
        // including when the host was already started before composition.
        inputForeground = lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)
        onVisible(inputForeground)
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> { inputForeground = true; onVisible(true) }
                Lifecycle.Event.ON_STOP -> {
                    inputForeground = false
                    releaseInput()
                    onVisible(false)
                }
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            releaseInput()
            onVisible(false)
            lifecycle.removeObserver(observer)
        }
    }

    LaunchedEffect(keyboardVisible) {
        if (keyboardVisible) {
            runCatching { focusRequester.requestFocus() }
        } else {
            textFieldFocused = false
            modifiers.forEach { keysym -> onKey(keysym, false) }
            modifiers = emptySet()
            // The text bridge is a per-typing staging buffer; dropping its
            // content on hide keeps a rebuild from replaying old text.
            textField = TextFieldValue("")
        }
    }

    val currentError = error ?: vnc.failure?.let { RemoteHostUiError(it.code, it.message) }
    val resolvedTitle = title ?: vnc.displayName
    val resolvedCloseLabel = closeLabel ?: stringResource(R.string.remote_close_session)

    // The options overlay must stay inside the viewer bounds, so the page
    // root is a Box even though the chrome itself is a plain Column.
    Box(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        Column(Modifier.fillMaxSize()) {
            if (!chromeHidden) {
                FloeToolbar(
                    title = resolvedTitle,
                    navigation = {
                        FloeToolbarIconButton(
                            icon = FloeIcons.ChevronBack,
                            contentDescription = resolvedCloseLabel,
                            onClick = { releaseInput(); onClose() },
                        )
                    },
                    actions = {
                        VncBarTextButton(
                            label = stringResource(R.string.remote_vnc_keyboard),
                            contentDescription = stringResource(R.string.remote_vnc_keyboard),
                            onClick = { releaseInput(); keyboardVisible = !keyboardVisible },
                            tint = if (keyboardVisible) Floe.colors.accent else Floe.colors.label,
                        )
                        FloeToolbarIconButton(
                            icon = FloeIcons.Ellipsis,
                            contentDescription = stringResource(R.string.remote_vnc_viewer_options),
                            onClick = { releaseInput(); menuOpen = true },
                            tint = if (menuOpen) Floe.colors.accent else Floe.colors.label,
                        )
                        FloeToolbarIconButton(
                            icon = FloeIcons.ChevronUp,
                            contentDescription = stringResource(R.string.remote_vnc_hide_controls),
                            onClick = {
                                releaseInput()
                                menuOpen = false
                                keyboardVisible = false
                                chromeHidden = true
                            },
                        )
                    },
                    showHairline = true,
                )

                currentError?.let {
                    VncErrorBanner(error = it, onDismiss = onDismissError)
                }
        }
        // Recovery actions remain reachable when the toolbar is collapsed.
        notice?.invoke()

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .background(androidx.compose.ui.graphics.Color.Black)
                .onSizeChanged { viewSize = it }
                .pointerInput(pointer, inputMode, menuOpen, chromeHidden, keyboardVisible,
                    inputForeground, vnc.width, vnc.height, vnc.state) {
                    if (!inputForeground || menuOpen || vnc.state != "connected" || vnc.width <= 0 || vnc.height <= 0) return@pointerInput
                    applyPointer(pointer.changeMode(inputMode))
                    detectVncPointerInput(
                        pointer = pointer,
                        transform = { currentTransform },
                        onInput = ::applyPointer,
                        onReleaseAll = ::releaseInput,
                        onWheel = onWheel,
                    ) { centroid, pan, gestureZoom ->
                        if (zoom <= 1.001f && abs(gestureZoom - 1f) < 0.02f && abs(pan.y) >= 1f) {
                            val point = if (inputMode == VncInputMode.TRACKPAD) pointer.position.pixel else
                                vncMapPoint(currentTransform, centroid.x, centroid.y)
                            point?.let {
                                onWheel(if (pan.y < 0f) "up" else "down",
                                    abs(pan.y).roundToInt().coerceIn(1, 20), it.first, it.second)
                            }
                        } else {
                            val nextZoom = vncClampZoom(zoom, gestureZoom)
                            val next = vncClampPan(viewSize.width.toFloat(), viewSize.height.toFloat(),
                                vnc.width, vnc.height, nextZoom, panX + pan.x, panY + pan.y)
                            zoom = nextZoom
                            panX = next.first
                            panY = next.second
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (imageBitmap != null && transform.displayWidth > 0f) {
                Canvas(Modifier.fillMaxSize()) {
                    drawImage(
                        image = imageBitmap,
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(imageBitmap.width, imageBitmap.height),
                        dstOffset = IntOffset(
                            transform.offsetX.roundToInt(),
                            transform.offsetY.roundToInt(),
                        ),
                        dstSize = IntSize(
                            transform.displayWidth.roundToInt(),
                            transform.displayHeight.roundToInt(),
                        ),
                        filterQuality = FilterQuality.Low,
                    )
                    if (inputMode == VncInputMode.TRACKPAD) {
                        val cursor = Path().apply {
                            moveTo(0f, 0f); lineTo(0f, 18f); lineTo(4.5f, 14.5f)
                            lineTo(8f, 22f); lineTo(11f, 20.5f); lineTo(7.5f, 13f)
                            lineTo(14f, 13f); close()
                        }
                        val cursorDensity = density
                        withTransform({
                            translate(transform.offsetX + pointerPosition.x * transform.scale,
                                transform.offsetY + pointerPosition.y * transform.scale)
                            scale(cursorDensity, cursorDensity, Offset.Zero)
                        }) {
                            drawPath(cursor, Color.White)
                            drawPath(cursor, Color.Black, style = Stroke(width = 1.5f))
                        }
                    }
                }
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    com.floe.android.design.FloeActivityIndicator(
                        description = stringResource(R.string.remote_vnc_connecting),
                    )
                    Spacer(Modifier.height(8.dp))
                    FloeText(
                        stringResource(R.string.remote_vnc_frame_unavailable),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            }

            if (chromeHidden) {
                // Immersive desktop: one reachable handle restores the chrome.
                // There is no timer and no hidden gesture; the desktop can
                // never trap the user.
                Column(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    currentError?.let {
                        VncErrorBanner(
                            error = it,
                            onDismiss = onDismissError,
                            modifier = Modifier.padding(horizontal = 8.dp),
                        )
                    }
                    VncControlHandle(
                        description = stringResource(R.string.remote_vnc_show_controls),
                        onClick = { chromeHidden = false },
                    )
                }
            }
        }

            if (!chromeHidden && keyboardVisible) {
                VncKeyboardBar(
                    textField = textField,
                    onTextFieldChange = { next ->
                        vncTextDiff(textField.text, next.text).forEach { event ->
                            when (event) {
                                is VncTextEdit.Insert -> onText(event.text)
                                is VncTextEdit.Backspace -> repeat(event.count) {
                                    onKey(VNC_XK_BACKSPACE, true)
                                    onKey(VNC_XK_BACKSPACE, false)
                                }
                            }
                        }
                        textField = next
                    },
                    focusRequester = focusRequester,
                    modifiers = modifiers,
                    onModifier = { keysym, down ->
                        modifiers = if (down) modifiers + keysym else modifiers - keysym
                        onKey(keysym, down)
                    },
                    onNamedKey = { keysym ->
                        onKey(keysym, true)
                        onKey(keysym, false)
                    },
                    onEnter = {
                        onKey(VNC_XK_RETURN, true)
                        onKey(VNC_XK_RETURN, false)
                    },
                    onHideKeyboard = {
                        keyboardVisible = false
                        focusManager.clearFocus()
                    },
                    onTextFocusChanged = { focused ->
                        if (focused) {
                            textFieldFocused = true
                        } else if (textFieldFocused) {
                            textFieldFocused = false
                            keyboardVisible = false
                        }
                    },
                )
            }
        }

        if (menuOpen) {
            BackHandler { menuOpen = false }
            Box(Modifier.fillMaxSize()) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(Floe.colors.scrim)
                        // Tap-outside dismisses; no ripple feedback on the scrim.
                        .pointerInput(vnc.sessionID) {
                            detectTapGestures { menuOpen = false }
                        },
                )
                Column(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 8.dp, end = 8.dp)
                        .widthIn(max = 340.dp)
                        .clip(RoundedCornerShape(FloeLayout.SettingsSheetCorner))
                        .background(Floe.colors.chromeSurface)
                        .border(
                            0.5.dp,
                            Floe.colors.chromeHairline,
                            RoundedCornerShape(FloeLayout.SettingsSheetCorner),
                        )
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FloeCapsuleAction(
                            label = stringResource(R.string.remote_vnc_fit),
                            onClick = {
                                zoom = 1f
                                panX = 0f
                                panY = 0f
                            },
                        )
                        FloeCapsuleAction(
                            label = "−",
                            onClick = { zoom = vncClampZoom(zoom, 0.8f) },
                        )
                        FloeCapsuleAction(
                            label = "+",
                            onClick = { zoom = vncClampZoom(zoom, 1.25f) },
                        )
                        FloeText(
                            "${(zoom * 100).roundToInt()}%",
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                        )
                        Spacer(Modifier.weight(1f))
                        FloeCapsuleAction(
                            label = stringResource(R.string.remote_vnc_release_input),
                            onClick = {
                                releaseInput()
                                menuOpen = false
                            },
                            showHairline = false,
                        )
                    }
                    FloeDivider()
                    FloeText(stringResource(R.string.remote_vnc_pointer_mode),
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    FloeSegmented(
                        options = listOf(stringResource(R.string.remote_vnc_direct_touch), stringResource(R.string.remote_vnc_trackpad)),
                        selectedIndex = if (inputMode == VncInputMode.DIRECT) 0 else 1,
                        onSelect = { index ->
                            releaseInput()
                            val next = if (index == 0) VncInputMode.DIRECT else VncInputMode.TRACKPAD
                            applyPointer(pointer.changeMode(next))
                            inputPreferences.save(next)
                            inputMode = next
                        },
                    )
                    FloeText(stringResource(if (inputMode == VncInputMode.TRACKPAD)
                        R.string.remote_vnc_trackpad_hint else R.string.remote_vnc_input_hint),
                        style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                    FloeDivider()
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        FloeBadgePill(
                            text = remoteVncStateLabel(vnc.state),
                            tone = when (vnc.state) {
                                "connected" -> FloeBadgeTone.SUCCESS
                                "failed" -> FloeBadgeTone.PENDING
                                else -> FloeBadgeTone.SECONDARY
                            },
                        )
                        Spacer(Modifier.width(8.dp))
                        FloeText(
                            "${vnc.host}:${vnc.port}" +
                                if (vnc.transport == "sshTunnel") " · SSH" else "",
                            style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel,
                            modifier = Modifier.weight(1f),
                        )
                    }
                    FloeText(
                        if (vnc.width > 0) "${vnc.width}×${vnc.height}" else "—",
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    vnc.inputIssue?.let { issue ->
                        FloeText(
                            stringResource(R.string.remote_vnc_input_issue, issue),
                            style = Floe.typography.metadata,
                            color = Floe.colors.destructive,
                        )
                    }
                    infoActions?.invoke(this)
                }
            }
            }
        }
}

/** Compact text control for the viewer bar: one short label, 48dp target. */
@Composable
private fun VncBarTextButton(
    label: String,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: androidx.compose.ui.graphics.Color = Floe.colors.accent,
) {
    Box(
        modifier = modifier
            .heightIn(min = FloeLayout.MinimumTarget)
            .clickable(enabled = true, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(
            label,
            style = Floe.typography.bodyEmphasized,
            color = tint,
            maxLines = 1,
        )
    }
}

/** Floating pill that brings the viewer chrome back in immersive mode. */
@Composable
private fun VncControlHandle(
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(FloeLayout.MinimumTarget)
    Box(
        modifier = modifier
            .clip(shape)
            .background(Floe.colors.chromeSurface.copy(alpha = 0.92f))
            .border(0.5.dp, Floe.colors.chromeHairline, shape),
    ) {
        FloeToolbarIconButton(
            icon = FloeIcons.ChevronDown,
            contentDescription = description,
            onClick = onClick,
        )
    }
}

/** Actionable connection error; stays visible over remote backgrounds. */
@Composable
private fun VncErrorBanner(
    error: RemoteHostUiError,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(Floe.colors.destructive.copy(alpha = 0.08f))
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 16.dp)
        Spacer(Modifier.width(8.dp))
        FloeText(
            remoteMessage(error.code),
            style = Floe.typography.metadata,
            color = Floe.colors.destructive,
            modifier = Modifier.weight(1f),
        )
        FloeCapsuleAction(
            label = stringResource(R.string.remote_cancel),
            onClick = onDismiss,
            showHairline = false,
            tint = Floe.colors.destructive,
        )
    }
}

internal const val VNC_XK_BACKSPACE = 0xFF08L
internal const val VNC_XK_TAB = 0xFF09L
internal const val VNC_XK_RETURN = 0xFF0DL
internal const val VNC_XK_ESCAPE = 0xFF1BL
internal const val VNC_XK_LEFT = 0xFF51L
internal const val VNC_XK_UP = 0xFF52L
internal const val VNC_XK_RIGHT = 0xFF53L
internal const val VNC_XK_DOWN = 0xFF54L
internal const val VNC_XK_SHIFT = 0xFFE1L
internal const val VNC_XK_CONTROL = 0xFFE3L
internal const val VNC_XK_ALT = 0xFFE9L
internal const val VNC_XK_META = 0xFFEBL

internal sealed interface VncTextEdit {
    data class Insert(val text: String) : VncTextEdit
    data class Backspace(val count: Int) : VncTextEdit
}

internal fun vncTextDiff(previous: String, next: String): List<VncTextEdit> {
    if (previous == next) return emptyList()
    var prefix = 0
    val limit = minOf(previous.length, next.length)
    while (prefix < limit && previous[prefix] == next[prefix]) prefix += 1
    val inserted = next.substring(prefix)
    val removed = previous.length - prefix
    val edits = mutableListOf<VncTextEdit>()
    if (removed > 0) edits.add(VncTextEdit.Backspace(removed))
    if (inserted.isNotEmpty()) edits.add(VncTextEdit.Insert(inserted))
    return edits
}

internal fun vncKeysymForAndroidKey(keyCode: Int): Long? = when (keyCode) {
    KeyEvent.KEYCODE_DEL -> VNC_XK_BACKSPACE
    KeyEvent.KEYCODE_FORWARD_DEL -> 0xFFFFL
    KeyEvent.KEYCODE_TAB -> VNC_XK_TAB
    KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> VNC_XK_RETURN
    KeyEvent.KEYCODE_ESCAPE -> VNC_XK_ESCAPE
    KeyEvent.KEYCODE_DPAD_LEFT -> VNC_XK_LEFT
    KeyEvent.KEYCODE_DPAD_UP -> VNC_XK_UP
    KeyEvent.KEYCODE_DPAD_RIGHT -> VNC_XK_RIGHT
    KeyEvent.KEYCODE_DPAD_DOWN -> VNC_XK_DOWN
    KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT -> VNC_XK_SHIFT
    KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> VNC_XK_CONTROL
    KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> VNC_XK_ALT
    KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> VNC_XK_META
    else -> null
}

/**
 * Compact input strip: one horizontally scrollable special-key row (held
 * modifier semantics unchanged) above the real text bridge. Hiding the
 * strip — button, system-keyboard back or focus loss — releases held
 * modifiers in the page and clears the staging text so nothing is replayed.
 */
@Composable
private fun VncKeyboardBar(
    textField: TextFieldValue,
    onTextFieldChange: (TextFieldValue) -> Unit,
    focusRequester: FocusRequester,
    modifiers: Set<Long>,
    onModifier: (Long, Boolean) -> Unit,
    onNamedKey: (Long) -> Unit,
    onEnter: () -> Unit,
    onHideKeyboard: () -> Unit,
    onTextFocusChanged: (Boolean) -> Unit,
) {
    val textBridgeDescription = stringResource(R.string.remote_vnc_type_text)
    Column(Modifier.fillMaxWidth()) {
        FloeDivider()
        Row(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 10.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            ModifierKey(stringResource(R.string.remote_vnc_ctrl), VNC_XK_CONTROL, modifiers, onModifier)
            ModifierKey(stringResource(R.string.remote_vnc_alt), VNC_XK_ALT, modifiers, onModifier)
            ModifierKey(stringResource(R.string.remote_vnc_shift), VNC_XK_SHIFT, modifiers, onModifier)
            ModifierKey(stringResource(R.string.remote_vnc_meta), VNC_XK_META, modifiers, onModifier)
            VncStripDivider()
            VncKeyChip(stringResource(R.string.remote_vnc_esc)) { onNamedKey(VNC_XK_ESCAPE) }
            VncKeyChip(stringResource(R.string.remote_vnc_tab)) { onNamedKey(VNC_XK_TAB) }
            VncKeyChip(stringResource(R.string.remote_vnc_enter), onClick = onEnter)
            VncKeyChip(stringResource(R.string.remote_vnc_backspace)) { onNamedKey(VNC_XK_BACKSPACE) }
            VncStripDivider()
            VncKeyChip(stringResource(R.string.remote_vnc_left)) { onNamedKey(VNC_XK_LEFT) }
            VncKeyChip(stringResource(R.string.remote_vnc_up)) { onNamedKey(VNC_XK_UP) }
            VncKeyChip(stringResource(R.string.remote_vnc_down)) { onNamedKey(VNC_XK_DOWN) }
            VncKeyChip(stringResource(R.string.remote_vnc_right)) { onNamedKey(VNC_XK_RIGHT) }
            VncStripDivider()
            FloeToolbarIconButton(
                icon = FloeIcons.ChevronDown,
                contentDescription = stringResource(R.string.remote_vnc_hide_keyboard),
                onClick = onHideKeyboard,
            )
        }
        BasicTextField(
            value = textField,
            onValueChange = onTextFieldChange,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 4.dp)
                .focusRequester(focusRequester)
                .onFocusChanged { state ->
                    onTextFocusChanged(state.hasFocus || state.isFocused)
                }
                .onPreviewKeyEvent { event ->
                    val native = event.nativeKeyEvent
                    val keysym = vncKeysymForAndroidKey(native.keyCode)
                    if (keysym != null && native.action == KeyEvent.ACTION_DOWN) {
                        onNamedKey(keysym)
                        true
                    } else {
                        false
                    }
                }
                .semantics {
                    contentDescription = textBridgeDescription
                },
            textStyle = Floe.typography.body.copy(color = Floe.colors.label),
            singleLine = true,
            maxLines = 1,
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = ImeAction.Send,
            ),
            keyboardActions = KeyboardActions(onSend = { onEnter() }),
        )
    }
}

@Composable
private fun VncStripDivider() {
    Box(
        Modifier
            .padding(horizontal = 2.dp)
            .width(0.5.dp)
            .height(22.dp)
            .background(Floe.colors.separator),
    )
}

@Composable
private fun VncKeyChip(
    label: String,
    onClick: () -> Unit,
) {
    FloeCapsuleAction(
        label = label,
        onClick = onClick,
        showHairline = false,
    )
}

@Composable
private fun ModifierKey(
    label: String,
    keysym: Long,
    active: Set<Long>,
    onModifier: (Long, Boolean) -> Unit,
) {
    FloeCapsuleAction(
        label = label,
        onClick = { onModifier(keysym, keysym !in active) },
        showHairline = false,
        tint = if (keysym in active) Floe.colors.accent else Floe.colors.label,
    )
}
