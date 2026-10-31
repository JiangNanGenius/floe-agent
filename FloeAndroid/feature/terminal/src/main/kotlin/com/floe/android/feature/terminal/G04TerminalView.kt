// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import android.graphics.Typeface
import android.view.KeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.termux.terminal.TerminalEmulator
import com.termux.view.TerminalRenderer
import kotlinx.coroutines.delay

/** Bytes to the PTY + grid changes; supplied by the host controller. The
 * ONLY side-effect channel of the view — no session, no process, no
 * authority lives here. */
interface TerminalTransport {
    fun write(bytes: ByteArray)
    fun resize(columns: Int, rows: Int)
}

data class TerminalViewSettings(
    val cellTextSizeSp: Float = 13f,
    val backgroundColor: Color = Color(0xFF101014),
    val keyboardVisible: Boolean = true,
)

data class TerminalSelection(
    val fromColumn: Int, val fromRow: Int,
    val toColumn: Int, val toRow: Int,
)

/**
 * The narrow Compose renderer for the reused Termux terminal-emulator.
 *
 * Rendering is delegated verbatim to the vendored [TerminalRenderer]
 * (android.graphics Paint/Canvas through `drawIntoCanvas`), so attributed
 * ANSI/VT colors, bold/underline/inverse/dim, block/bar/underline cursor
 * shapes, CJK double-width cells, combining characters and font-mismatch
 * scaling behave exactly like upstream. This wrapper adds ONLY the Compose
 * plumbing: grid measurement + true native resize, transcript scroll,
 * long-press selection, double-tap word copy, program clipboard, real IME
 * input through [TerminalImeProxy], physical
 * keys, cursor blink pacing and bounded accessibility text.
 *
 * There is NO fake text log here: the emulator is a real VT parser and
 * every keystroke is real ordered input.
 */
@Composable
fun G04TerminalView(
    engine: G04TerminalEngine,
    transport: TerminalTransport,
    modifier: Modifier = Modifier,
    settings: TerminalViewSettings = TerminalViewSettings(),
    statusLine: String = "",
    onCopyTextChanged: (String) -> Unit = {},
) {
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val density = LocalDensity.current
    var revision by remember { mutableIntStateOf(0) }
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var scrollRows by remember { mutableIntStateOf(0) }
    var selection by remember { mutableStateOf<TerminalSelection?>(null) }
    val copyTextConsumer by rememberUpdatedState(onCopyTextChanged)
    LaunchedEffect(engine, selection, scrollRows, revision) {
        val selected = selection
        copyTextConsumer(
            if (selected != null) engine.selectedText(
                selected.fromColumn, selected.fromRow, selected.toColumn, selected.toRow,
            ) else engine.viewportText(scrollRows, maxCharacters = 65_536),
        )
    }

    val textSizePx = remember(density, settings.cellTextSizeSp) {
        with(density) { settings.cellTextSizeSp.sp.toPx() }.toInt().coerceAtLeast(8)
    }
    val renderer = remember(textSizePx) { TerminalRenderer(textSizePx, Typeface.MONOSPACE) }

    // The pane auto-opens the keyboard ONCE when it first becomes visible.
    // Hiding the IME with Back does not set keyboardVisible=false, so a plain
    // effect on (keyboardVisible, engine) used to re-show the IME on every tab
    // selection / engine change and steal focus from a newly selected tab or
    // the composer. The explicit tap on the PTY surface is the retry path.
    var keyboardAutoRequested by remember { mutableStateOf(false) }

    val imeProxy = remember(engine, transport) {
        TerminalImeProxy(context, object : TerminalImeProxy.TerminalImeSink {
            override fun commitText(text: String) {
                transport.write(TerminalInputEncoder.encodeText(text))
            }

            override fun keyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_MULTIPLE) {
                    // Batch-injected text (ACTION_MULTIPLE characters):
                    // real ordered PTY bytes, never EditText retention.
                    val text = event.characters.orEmpty()
                    if (text.isEmpty()) return false
                    transport.write(TerminalInputEncoder.encodeText(text))
                    return true
                }
                if (event.action != KeyEvent.ACTION_DOWN) return true
                val bytes = engine.encodePhysicalKeyEvent(event) ?: return false
                transport.write(bytes)
                return true
            }
        })
    }

    // UI delegate: the pane registers itself for the engine's lifetime; a
    // NEW pane takes over cleanly (view reconstruction never restarts the
    // engine or the native session).
    DisposableEffect(engine) {
        val previous = engine.ui
        engine.ui = object : TerminalUiDelegate {
            override fun onTitleChanged(title: String) { revision += 1 }
            override fun onBell() { revision += 1 }
            override fun onTextChanged() { revision += 1 }
            override fun onColorsChanged() { revision += 1 }
            override fun onCursorVisibilityChanged(visible: Boolean) { revision += 1 }
            override fun onProgramClipboardCopy(text: String) {
                clipboardManager.setText(AnnotatedString(text))
            }
            override fun requestProgramClipboardPaste(): String? =
                clipboardManager.getText()?.text
        }
        onDispose { engine.ui = previous }
    }

    // A pending focus/show posted by THIS proxy must not run after the pane
    // (or its AndroidView) has been disposed. Removing the callback here also
    // fences a late IME request when the user switches tab or conversation.
    DisposableEffect(imeProxy) {
        onDispose { imeProxy.dispose() }
    }

    // Cursor blink pacing (upstream shouldCursorBeVisible semantics).
    LaunchedEffect(engine) {
        engine.setCursorBlinkingEnabled(true)
        var blink = true
        while (true) {
            delay(530)
            blink = !blink
            engine.setCursorBlink(blink)
            revision += 1
        }
    }

    // Grid: measure the pixel area, resize the emulator AND the native
    // session through the transport (true resize, not visual reflow).
    LaunchedEffect(viewSize, renderer, engine) {
        if (viewSize.width <= 0 || viewSize.height <= 0) return@LaunchedEffect
        // Cell metrics through the renderer's own public getters (the fields
        // themselves stay package-private upstream — we do not touch them).
        val columns = (viewSize.width / renderer.fontWidth).toInt()
            .coerceIn(G04TerminalEngine.MinimumColumns, G04TerminalEngine.MaximumColumns)
        val rows = ((viewSize.height / renderer.fontLineSpacing).toInt())
            .coerceIn(G04TerminalEngine.MinimumRows, G04TerminalEngine.MaximumRows)
        val applied = engine.resizeTo(columns, rows)
        transport.resize(applied.first, applied.second)
        scrollRows = scrollRows.coerceAtMost(engine.activeTranscriptRows())
        revision += 1
    }

    // Soft keyboard follows the pane's toggle. The first visible terminal
    // requests it exactly once; a later tab/engine does not re-request it.
    // Turning the setting off cancels any pending request and re-arms the
    // next explicit on.
    LaunchedEffect(settings.keyboardVisible) {
        if (!settings.keyboardVisible) {
            keyboardAutoRequested = false
            imeProxy.hideKeyboard()
        } else if (!keyboardAutoRequested) {
            keyboardAutoRequested = true
            imeProxy.showKeyboard()
        }
    }

    val cellWidth = renderer.fontWidth
    val cellHeight = renderer.fontLineSpacing.toFloat()

    fun cellAt(position: Offset): Pair<Int, Int> =
        (position.x / cellWidth).toInt().coerceAtLeast(0) to
            (position.y / cellHeight).toInt().coerceAtLeast(0)

    fun commitSelection(from: Pair<Int, Int>, to: Pair<Int, Int>) {
        // rows are SCREEN rows; convert to EXTERNAL buffer rows so the
        // vendored renderer highlights the right lines while scrolled.
        val a = from to to
        val first = if (a.second.second < a.first.second ||
            (a.second.second == a.first.second && a.second.first < a.first.first)) a.second else a.first
        val last = if (first === a.first) a.second else a.first
        selection = TerminalSelection(first.first, first.second - scrollRows,
            last.first, last.second - scrollRows)
        revision += 1
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(settings.backgroundColor)
            .onSizeChanged { viewSize = it }
            .semantics {
                contentDescription = terminalAccessibilityLabel(engine, statusLine, revision, scrollRows)
            }
            // Physical/hardware key events -> KeyHandler tables in the sink.
            .onPreviewKeyEvent { event ->
                if (event.type == KeyEventType.KeyDown) {
                    // The Compose wrapper exposes the real android.view
                    // KeyEvent; the engine's mapping stays the native one
                    // (KeyHandler tables + the event's unicode character,
                    // so physical keyboards and injected key events reach
                    // the PTY instead of the focused proxy's defaults).
                    val bytes = engine.encodePhysicalKeyEvent(event.nativeKeyEvent)
                    if (bytes != null) {
                        transport.write(bytes)
                        true
                    } else false
                } else false
            }
            // Mouse wheel / trackpad -> transcript scroll (bounded). The
            // pinned Compose release exposes wheel deltas through the public
            // pointer-input event loop (awaitPointerEventScope), not via any
            // onPointerEvent modifier — behavior kept identical.
            .pointerInput(engine, cellHeight) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        if (event.type == PointerEventType.Scroll) {
                            val delta = event.changes.firstOrNull()?.scrollDelta?.y ?: 0f
                            if (delta != 0f) {
                                val rows = (delta / cellHeight).toInt()
                                if (rows != 0) {
                                    scrollRows = (scrollRows + rows)
                                        .coerceIn(0, engine.activeTranscriptRows())
                                    revision += 1
                                    event.changes.forEach { it.consume() }
                                }
                            }
                        }
                    }
                }
            }
            // ONE pointer gesture state machine owns the terminal surface.
            // It replaces the old sibling tap/drag recognizers, whose
            // independent consumption could not prove that a long press
            // followed by a drag actually reaches the drag path. A plain drag
            // pans the transcript, a long press starts an explicit selection
            // that dragging extends, a tap keeps the old focus/mouse-report
            // behavior, and a double tap copies the word. Long press never
            // pastes or copies: toolbar Paste/Copy and double-tap copy are the
            // explicit clipboard paths.
            .pointerInput(engine, transport, cellWidth, cellHeight) {
                val arbiter = TerminalGestureArbiter(
                    touchSlop = viewConfiguration.touchSlop,
                    longPressTimeoutMillis = viewConfiguration.longPressTimeoutMillis,
                    doubleTapTimeoutMillis = viewConfiguration.doubleTapTimeoutMillis,
                    doubleTapMinTimeMillis = viewConfiguration.doubleTapMinTimeMillis,
                )
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    down.consume()
                    val pointerId = down.id
                    val anchorCell = cellAt(down.position)
                    var lastY = down.position.y
                    var panCarry = 0f
                    arbiter.down(down.position.x, down.position.y, down.uptimeMillis)
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        val change = event.changes.firstOrNull { it.id == pointerId }
                        if (change == null) {
                            arbiter.cancel()
                            break
                        }
                        if (change.changedToUpIgnoreConsumed()) {
                            when (arbiter.up(change.uptimeMillis)) {
                                TerminalGestureArbiter.Release.Tap -> {
                                    if (engine.mouseTrackingActive()) {
                                        val (column, row) = cellAt(down.position)
                                        // Mouse reporting expects SCREEN rows
                                        // (the app sits at the prompt bottom
                                        // while tracking).
                                        engine.sendMouseEvent(
                                            TerminalEmulator.MOUSE_LEFT_BUTTON,
                                            column, row, true)
                                        engine.sendMouseEvent(
                                            TerminalEmulator.MOUSE_LEFT_BUTTON,
                                            column, row, false)
                                        revision += 1
                                    } else {
                                        selection = null
                                        imeProxy.showKeyboard()
                                        revision += 1
                                    }
                                }
                                TerminalGestureArbiter.Release.DoubleTap -> {
                                    val (column, row) = cellAt(down.position)
                                    val word = engine.wordAt(column, row - scrollRows)
                                    if (word.isNotEmpty()) {
                                        clipboardManager.setText(AnnotatedString(word))
                                    }
                                }
                                TerminalGestureArbiter.Release.LongPress -> {
                                    commitSelection(anchorCell, anchorCell)
                                }
                                TerminalGestureArbiter.Release.None -> Unit
                            }
                            break
                        }
                        if (change.isConsumed) {
                            arbiter.cancel()
                            break
                        }
                        when (arbiter.move(
                            change.position.x,
                            change.position.y,
                            change.uptimeMillis,
                        )) {
                            TerminalGestureArbiter.Mode.Pan -> {
                                // Finger DOWN drags the transcript with it:
                                // earlier rows come into view; UP returns
                                // toward the prompt. Fractional rows carry
                                // across events and both ends clamp to the
                                // real transcript.
                                val delta = change.position.y - lastY
                                lastY = change.position.y
                                if (delta != 0f) {
                                    val step = TerminalScrollPan.step(
                                        scrollRows = scrollRows,
                                        carry = panCarry,
                                        dragY = delta,
                                        cellHeightPx = cellHeight,
                                        transcriptRows = engine.activeTranscriptRows(),
                                    )
                                    panCarry = step.carry
                                    if (step.scrollRows != scrollRows) {
                                        scrollRows = step.scrollRows
                                        revision += 1
                                    }
                                }
                                change.consume()
                            }
                            TerminalGestureArbiter.Mode.Selection -> {
                                commitSelection(anchorCell, cellAt(change.position))
                                change.consume()
                            }
                            TerminalGestureArbiter.Mode.Undecided -> Unit
                        }
                    }
                }
            }
            .drawWithContent {
                revision // read token: re-draw on every engine change
                scrollRows
                selection
                drawContent()
                val topRow = -scrollRows
                drawIntoCanvas { canvas ->
                    val emulator = engine.emulatorForRender()
                    val native = canvas.nativeCanvas
                    val sel = selection
                    if (sel != null) {
                        renderer.render(emulator, native, topRow,
                            sel.fromRow, sel.toRow, sel.fromColumn, sel.toColumn)
                    } else {
                        // selectionY1 > selectionY2 disables the highlight
                        renderer.render(emulator, native, topRow, 1, 0, 0, 0)
                    }
                }
            },
    ) {
        // Focus proxy: a real EditText + custom InputConnection, 2 px and
        // transparent; the visible PTY is the only text display.
        AndroidView(
            factory = { imeProxy.view },
            modifier = Modifier
                .size(2.dp)
                .align(Alignment.BottomEnd),
        )
    }
}

private fun terminalAccessibilityLabel(
    engine: G04TerminalEngine,
    statusLine: String,
    revision: Int,
    scrollRows: Int,
): String {
    val text = runCatching { engine.viewportText(scrollRows) }.getOrDefault("")
    val status = statusLine.take(512)
    return if (status.isBlank()) text.ifBlank { "Terminal" } else "$status\n$text"
}
