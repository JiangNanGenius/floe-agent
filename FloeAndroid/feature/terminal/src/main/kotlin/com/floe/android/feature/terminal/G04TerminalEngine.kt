// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import android.view.KeyEvent
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TerminalSessionClient

/**
 * Presentation-side terminal engine: the REUSED Termux terminal-emulator
 * (pinned v0.118.3 subset; see PROVENANCE-TERMUX.md) driven over an
 * EXTERNAL PTY pipe. This class owns no process, no session lifecycle and
 * no runtime: bytes the emulator generates (keyboard responses, mouse
 * reports, OSC reads) leave only through [TerminalEngineHost.writeToPty],
 * which the trusted App host controller relays to the native owner (Swift
 * `G04TerminalStore` over the ORIGINAL ShellSessionCenter). UI effects
 * (title/bell/clipboard/paste) go to the optional [ui] delegate set by the
 * attached pane.
 *
 * Threading contract: all methods must be called from ONE thread (the UI
 * thread). The upstream emulator is not thread-safe; the host pump marshals
 * raw PTY pages onto the UI thread before feeding them. This mirrors the
 * iOS split exactly (view is dumb, native owns semantics).
 */
interface TerminalEngineHost {
    /** Bytes the EMULATOR produced for the PTY input stream, ordered. */
    fun writeToPty(bytes: ByteArray)
    /** Emulator-internal diagnostics (mapped to the app log, bounded). */
    fun log(level: String, message: String)
}

/** Pane-owned UI side channels; the pane may come and go, the engine
 * survives (service-owned session semantics — view reconstruction is NOT
 * a navigation or a teardown signal). */
interface TerminalUiDelegate {
    fun onTitleChanged(title: String)
    fun onBell()
    fun onTextChanged()
    fun onColorsChanged()
    fun onCursorVisibilityChanged(visible: Boolean)
    /** OSC 52 copy request from the program. */
    fun onProgramClipboardCopy(text: String)
    /** OSC 52 paste request: returns the current clipboard, or null. */
    fun requestProgramClipboardPaste(): String?
}

class G04TerminalEngine(
    initialColumns: Int,
    initialRows: Int,
    transcriptRows: Int = DefaultTranscriptRows,
    private val host: TerminalEngineHost,
) {
    companion object {
        const val DefaultTranscriptRows = 2000
        const val MinimumColumns = 20
        const val MaximumColumns = 500
        const val MinimumRows = 5
        const val MaximumRows = 200
    }

    var ui: TerminalUiDelegate? = null

    private val outputAdapter = object : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) {
            host.writeToPty(data.copyOfRange(offset, offset + count))
        }

        override fun titleChanged(oldTitle: String?, newTitle: String?) {
            if (newTitle != null) ui?.onTitleChanged(newTitle)
        }

        override fun onCopyTextToClipboard(text: String?) {
            if (text != null) ui?.onProgramClipboardCopy(text)
        }

        override fun onPasteTextFromClipboard() {
            val text = ui?.requestProgramClipboardPaste()
            if (!text.isNullOrEmpty()) pasteText(text)
        }

        override fun onBell() { ui?.onBell() }

        override fun onColorsChanged() { ui?.onColorsChanged() }
    }

    /** PATCH-1 interface (see PROVENANCE-TERMUX.md): exactly the members
     * the vendored emulator references — cursor style/visibility and the
     * Logger channels. No TerminalSession-typed callback exists here, so no
     * Termux process lifecycle can leak into this view layer. */
    private val clientAdapter = object : TerminalSessionClient {
        override fun onTerminalCursorStateChange(state: Boolean) {
            ui?.onCursorVisibilityChanged(state)
        }

        override fun getTerminalCursorStyle(): Int =
            TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK

        override fun logError(tag: String, message: String) = host.log("error", "$tag $message")
        override fun logWarn(tag: String, message: String) = host.log("warn", "$tag $message")
        override fun logInfo(tag: String, message: String) = host.log("info", "$tag $message")
        override fun logDebug(tag: String, message: String) = host.log("debug", "$tag $message")
        override fun logVerbose(tag: String, message: String) = host.log("verbose", "$tag $message")
        override fun logStackTraceWithMessage(tag: String, message: String, e: Exception?) =
            host.log("error", "$tag $message ${e?.message.orEmpty()}")
        override fun logStackTrace(tag: String, e: Exception?) = host.log("error", "$tag ${e?.message.orEmpty()}")
    }

    // Explicit property type: the output adapter's members route back into
    // this class (pasteText), so an inferred declaration type is a
    // type-inference cycle. The compiler's own workaround applies here.
    private val emulator: TerminalEmulator = TerminalEmulator(
        /* session = */ outputAdapter,
        /* columns = */ clampColumns(initialColumns),
        /* rows = */ clampRows(initialRows),
        /* cellWidthPixels = */ 1,
        /* cellHeightPixels = */ 1,
        /* transcriptRows = */ transcriptRows,
        /* client = */ clientAdapter,
    )

    val columns: Int get() = emulator.mColumns
    val rows: Int get() = emulator.mRows

    /** Direct access for the vendored `TerminalRenderer` (the render path
     * is upstream code; this wrapper adds no rendering semantics). */
    fun emulatorForRender(): TerminalEmulator = emulator

    fun feed(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        emulator.append(bytes, bytes.size)
        ui?.onTextChanged()
    }

    /** Applies a renderer-chosen grid; returns the applied (columns, rows)
     * clamped to the bounds the ORIGINAL session resize accepts. */
    fun resizeTo(columns: Int, rows: Int): Pair<Int, Int> {
        val appliedColumns = clampColumns(columns)
        val appliedRows = clampRows(rows)
        if (appliedColumns == emulator.mColumns && appliedRows == emulator.mRows) {
            return appliedColumns to appliedRows
        }
        emulator.resize(appliedColumns, appliedRows, 1, 1)
        return appliedColumns to appliedRows
    }

    fun cursorRow(): Int = emulator.getCursorRow()
    fun cursorColumn(): Int = emulator.getCursorCol()
    fun cursorEnabled(): Boolean = emulator.isCursorEnabled()
    fun cursorVisible(): Boolean = emulator.shouldCursorBeVisible()
    fun setCursorBlink(blink: Boolean) = emulator.setCursorBlinkState(blink)
    fun setCursorBlinkingEnabled(enabled: Boolean) = emulator.setCursorBlinkingEnabled(enabled)
    fun cursorKeysApplication(): Boolean = emulator.isCursorKeysApplicationMode()
    fun keypadApplication(): Boolean = emulator.isKeypadApplicationMode()
    fun mouseTrackingActive(): Boolean = emulator.isMouseTrackingActive()
    fun activeTranscriptRows(): Int = emulator.getScreen().getActiveTranscriptRows()

    /** Selection extraction with the ORIGINAL line-joining semantics (no
     * soft-wrap newlines inside logically-joined lines). */
    fun selectedText(fromColumn: Int, fromRow: Int, toColumn: Int, toRow: Int): String =
        emulator.getSelectedText(fromColumn, fromRow, toColumn, toRow)

    fun wordAt(column: Int, row: Int): String = emulator.getScreen().getWordAtLocation(column, row)

    /** Paste with the ORIGINAL bracketed-paste semantics (DECSET 2004 is
     * tracked inside the reused emulator; marker wrapping and CRLF
     * normalization are exactly upstream). */
    fun pasteText(text: String) = emulator.paste(text)

    fun sendMouseEvent(button: Int, column: Int, row: Int, pressed: Boolean) =
        emulator.sendMouseEvent(button, column, row, pressed)

    fun title(): String = emulator.getTitle() ?: ""

    /** Screen text for accessibility (bounded by the caller). */
    fun visibleText(): String = emulator.getScreen().getSelectedText(0, 0, columns, rows, false)

    fun resetEmulator() = emulator.reset()

    /** Physical key bytes routed through the reused KeyHandler tables. */
    fun encodeKeyEvent(event: KeyEvent): ByteArray? =
        TerminalInputEncoder.encodeKeyEvent(event, cursorKeysApplication(), keypadApplication())

    /** Hardware key bytes: KeyHandler tables first, then the event's
     * printable unicode character (external keyboards / injected events);
     * Android system BACK stays platform-owned and the dedicated ESCAPE
     * key sends PTY ESC (see TerminalInputEncoder.encodePhysicalKey). */
    fun encodePhysicalKeyEvent(event: KeyEvent): ByteArray? =
        TerminalInputEncoder.encodePhysicalKeyEvent(
            event, cursorKeysApplication(), keypadApplication(),
        )

    private fun clampColumns(value: Int) = value.coerceIn(MinimumColumns, MaximumColumns)
    private fun clampRows(value: Int) = value.coerceIn(MinimumRows, MaximumRows)
}
