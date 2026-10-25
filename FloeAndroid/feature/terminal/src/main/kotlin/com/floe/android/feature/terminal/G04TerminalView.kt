// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import android.graphics.Typeface
import android.view.KeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
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
 * selection/copy/paste, real IME input through [TerminalImeProxy], physical
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
) {
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val density = LocalDensity.current
    var revision by remember { mutableIntStateOf(0) }
    var viewSize by remember { mutableStateOf(IntSize.Zero) }
    var scrollRows by remember { mutableIntStateOf(0) }
    var selection by remember { mutableStateOf<TerminalSelection?>(null) }

    val textSizePx = remember(density, settings.cellTextSizeSp) {
        with(density) { settings.cellTextSizeSp.sp.toPx() }.toInt().coerceAtLeast(8)
    }
    val renderer = remember(textSizePx) { TerminalRenderer(textSizePx, Typeface.MONOSPACE) }

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

    // Soft keyboard follow the pane's toggle.
    LaunchedEffect(settings.keyboardVisible, engine) {
        if (settings.keyboardVisible) imeProxy.showKeyboard() else imeProxy.hideKeyboard()
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
                contentDescription = terminalAccessibilityLabel(engine, statusLine, revision)
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
            .pointerInput(engine, transport) {
                detectTapGestures(
                    onTap = { position ->
                        if (engine.mouseTrackingActive()) {
                            val (column, row) = cellAt(position)
                            // Mouse reporting expects SCREEN rows (the app
                            // is at the prompt bottom while tracking).
                            engine.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON,
                                column, row, true)
                            engine.sendMouseEvent(TerminalEmulator.MOUSE_LEFT_BUTTON,
                                column, row, false)
                            revision += 1
                        } else {
                            selection = null
                            imeProxy.showKeyboard()
                            revision += 1
                        }
                    },
                    onDoubleTap = { position ->
                        val (column, row) = cellAt(position)
                        val word = engine.wordAt(column, row - scrollRows)
                        if (word.isNotEmpty()) clipboardManager.setText(AnnotatedString(word))
                    },
                    onLongPress = {
                        val current = selection
                        if (current != null) {
                            val text = engine.selectedText(current.fromColumn, current.fromRow,
                                current.toColumn, current.toRow)
                            if (text.isNotEmpty()) clipboardManager.setText(AnnotatedString(text))
                        } else {
                            val text = clipboardManager.getText()?.text
                            if (!text.isNullOrEmpty()) engine.pasteText(text)
                        }
                    },
                )
            }
            .pointerInput(engine, cellWidth, cellHeight) {
                var anchor: Pair<Int, Int>? = null
                detectDragGestures(
                    onDragStart = { position ->
                        anchor = cellAt(position)
                        anchor?.let { commitSelection(it, it) }
                    },
                    onDrag = { change, dragAmount ->
                        change.consume()
                        val start = anchor ?: return@detectDragGestures
                        // Drag inside the scroll margin pans the transcript
                        // only when the user is already scrolled or pulls
                        // past the top edge; selection stays the default.
                        if (scrollRows > 0 && dragAmount.y < -cellHeight / 2f) {
                            scrollRows = (scrollRows - 1).coerceAtLeast(0)
                        }
                        commitSelection(start, cellAt(change.position))
                    },
                    onDragEnd = { anchor = null },
                    onDragCancel = { anchor = null },
                )
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
): String {
    val text = runCatching { engine.visibleText() }.getOrDefault("").trim().take(800)
    return if (statusLine.isBlank()) text.ifBlank { "Terminal" } else "$statusLine\n$text"
}
