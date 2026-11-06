// SPDX-License-Identifier: MPL-2.0
//
// Full-screen VNC viewer. Presentation only: the App controller owns the
// real RFB session, frame lease and input lane. This page computes the
// fit/zoom/pan mapping, sends pointer/key/wheel events and releases pressed
// input when the view leaves the foreground or composition.

package com.floe.android.feature.remote

import android.view.KeyEvent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
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
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeToolbar
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
) {
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var zoom by remember(vnc.sessionID) { mutableFloatStateOf(1f) }
    var panX by remember(vnc.sessionID) { mutableFloatStateOf(0f) }
    var panY by remember(vnc.sessionID) { mutableFloatStateOf(0f) }
    var keyboardVisible by remember(vnc.sessionID) { mutableStateOf(false) }
    var modifiers by remember(vnc.sessionID) { mutableStateOf(emptySet<Long>()) }
    var textField by remember(vnc.sessionID) { mutableStateOf(TextFieldValue("")) }
    val focusRequester = remember { FocusRequester() }

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

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, vnc.sessionID) {
        val lifecycle = lifecycleOwner.lifecycle
        // Dialog contexts need not be LifecycleOwners. Re-entering the viewer
        // after its software picker must resume frame delivery immediately,
        // including when the host was already started before composition.
        onVisible(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> onVisible(true)
                Lifecycle.Event.ON_STOP -> {
                    onReleaseAll()
                    onVisible(false)
                }
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {
            onReleaseAll()
            onVisible(false)
            lifecycle.removeObserver(observer)
        }
    }

    LaunchedEffect(keyboardVisible) {
        if (keyboardVisible) {
            runCatching { focusRequester.requestFocus() }
        } else {
            modifiers.forEach { keysym -> onKey(keysym, false) }
            modifiers = emptySet()
        }
    }

    Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface)) {
        FloeToolbar(
            title = vnc.displayName,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.remote_close_session),
                    onClick = onClose,
                )
            },
            actions = {
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_vnc_fit),
                    onClick = {
                        zoom = 1f
                        panX = 0f
                        panY = 0f
                    },
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = "−",
                    onClick = { zoom = vncClampZoom(zoom, 0.8f) },
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = "+",
                    onClick = { zoom = vncClampZoom(zoom, 1.25f) },
                    showHairline = false,
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_vnc_keyboard),
                    onClick = { keyboardVisible = !keyboardVisible },
                    tint = if (keyboardVisible) Floe.colors.accent else Floe.colors.label,
                )
            },
            showHairline = true,
        )

        val currentError = error ?: vnc.failure?.let { RemoteHostUiError(it.code, it.message) }
        currentError?.let {
            Row(
                Modifier.fillMaxWidth()
                    .background(Floe.colors.destructive.copy(alpha = 0.08f))
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconGlyph(FloeIcons.WarningTriangle, Floe.colors.destructive, 16.dp)
                Spacer(Modifier.width(8.dp))
                FloeText(
                    remoteMessage(it.code),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                    modifier = Modifier.weight(1f),
                )
                FloeCapsuleAction(
                    label = stringResource(R.string.remote_cancel),
                    onClick = onDismissError,
                    showHairline = false,
                    tint = Floe.colors.destructive,
                )
            }
        }

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
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
            FloeText(
                if (vnc.width > 0) "${vnc.width}×${vnc.height}" else "—",
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
            )
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .background(androidx.compose.ui.graphics.Color.Black)
                .onSizeChanged { viewSize = it }
                .pointerInput(vnc.sessionID, vnc.width, vnc.height) {
                    detectTapGestures(
                        onTap = { point ->
                            vncMapPoint(currentTransform, point.x, point.y)?.let { (x, y) ->
                                onPointerButton("left", true, x, y)
                                onPointerButton("left", false, x, y)
                            }
                        },
                        onLongPress = { point ->
                            vncMapPoint(currentTransform, point.x, point.y)?.let { (x, y) ->
                                onPointerButton("right", true, x, y)
                                onPointerButton("right", false, x, y)
                            }
                        },
                    )
                }
                .pointerInput(vnc.sessionID) {
                    var lastPoint: Pair<Int, Int>? = null
                    detectDragGestures(
                        onDragStart = { point ->
                            lastPoint = vncMapPoint(currentTransform, point.x, point.y)
                            lastPoint?.let { (x, y) -> onPointerButton("left", true, x, y) }
                        },
                        onDragEnd = {
                            lastPoint?.let { (x, y) -> onPointerButton("left", false, x, y) }
                            lastPoint = null
                        },
                        onDragCancel = {
                            lastPoint?.let { (x, y) -> onPointerButton("left", false, x, y) }
                            lastPoint = null
                        },
                    ) { change, _ ->
                        vncMapPoint(currentTransform, change.position.x, change.position.y)?.let { (x, y) ->
                            lastPoint = x to y
                            onPointerMove(x, y)
                        }
                    }
                }
                .pointerInput(vnc.sessionID) {
                    detectTransformGestures { centroid, pan, gestureZoom, _ ->
                        if (zoom <= 1.001f && abs(gestureZoom - 1f) < 0.02f &&
                            abs(pan.y) >= 1f
                        ) {
                            // Two-finger vertical drag at fit zoom is the
                            // touch wheel; when zoomed it pans instead.
                            vncMapPoint(currentTransform, centroid.x, centroid.y)?.let { point ->
                                onWheel(
                                    if (pan.y < 0f) "up" else "down",
                                    minOf(20, maxOf(1, abs(pan.y).roundToInt())),
                                    point.first,
                                    point.second,
                                )
                            }
                        } else {
                            val nextZoom = vncClampZoom(zoom, gestureZoom)
                            val (nextX, nextY) = vncClampPan(
                                viewSize.width.toFloat(),
                                viewSize.height.toFloat(),
                                vnc.width,
                                vnc.height,
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
                .pointerInput(vnc.sessionID, vnc.width, vnc.height) {
                    awaitPointerEventScope {
                        while (true) {
                            val event = awaitPointerEvent()
                            if (event.type == PointerEventType.Scroll) {
                                val change = event.changes.firstOrNull() ?: continue
                                val delta = change.scrollDelta.y
                                if (abs(delta) > 0.01f) {
                                    val point = vncMapPoint(
                                        transform,
                                        change.position.x,
                                        change.position.y,
                                    ) ?: continue
                                    onWheel(
                                        if (delta < 0f) "up" else "down",
                                        minOf(20, maxOf(1, abs(delta).roundToInt())),
                                        point.first,
                                        point.second,
                                    )
                                    change.consume()
                                }
                            }
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
        }

        if (keyboardVisible) {
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
            )
        }

        FloeDivider()
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FloeText(
                if (vnc.width > 0) {
                    stringResource(R.string.remote_vnc_input_hint)
                } else {
                    stringResource(R.string.remote_vnc_connecting)
                },
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            vnc.inputIssue?.let { issue ->
                FloeText(
                    stringResource(R.string.remote_vnc_input_issue, issue),
                    style = Floe.typography.metadata,
                    color = Floe.colors.destructive,
                )
            }
        }
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

@Composable
private fun VncKeyboardBar(
    textField: TextFieldValue,
    onTextFieldChange: (TextFieldValue) -> Unit,
    focusRequester: FocusRequester,
    modifiers: Set<Long>,
    onModifier: (Long, Boolean) -> Unit,
    onNamedKey: (Long) -> Unit,
    onEnter: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ModifierKey(stringResource(R.string.remote_vnc_ctrl), VNC_XK_CONTROL, modifiers, onModifier)
            ModifierKey(stringResource(R.string.remote_vnc_alt), VNC_XK_ALT, modifiers, onModifier)
            ModifierKey(stringResource(R.string.remote_vnc_shift), VNC_XK_SHIFT, modifiers, onModifier)
            ModifierKey(stringResource(R.string.remote_vnc_meta), VNC_XK_META, modifiers, onModifier)
        }
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_esc),
                onClick = { onNamedKey(VNC_XK_ESCAPE) },
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_tab),
                onClick = { onNamedKey(VNC_XK_TAB) },
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_enter),
                onClick = onEnter,
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_backspace),
                onClick = { onNamedKey(VNC_XK_BACKSPACE) },
                showHairline = false,
            )
        }
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_left),
                onClick = { onNamedKey(VNC_XK_LEFT) },
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_up),
                onClick = { onNamedKey(VNC_XK_UP) },
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_down),
                onClick = { onNamedKey(VNC_XK_DOWN) },
                showHairline = false,
            )
            FloeCapsuleAction(
                label = stringResource(R.string.remote_vnc_right),
                onClick = { onNamedKey(VNC_XK_RIGHT) },
                showHairline = false,
            )
        }
        Spacer(Modifier.height(6.dp))
        BasicTextField(
            value = textField,
            onValueChange = onTextFieldChange,
            modifier = Modifier.fillMaxWidth()
                .focusRequester(focusRequester)
                .onPreviewKeyEvent { event ->
                    val native = event.nativeKeyEvent
                    val keysym = vncKeysymForAndroidKey(native.keyCode)
                    if (keysym != null && native.action == KeyEvent.ACTION_DOWN) {
                        onNamedKey(keysym)
                        true
                    } else {
                        false
                    }
                },
            textStyle = Floe.typography.body.copy(color = Floe.colors.label),
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
