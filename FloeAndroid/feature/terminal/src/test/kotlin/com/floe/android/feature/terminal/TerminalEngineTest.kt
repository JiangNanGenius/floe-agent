// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import android.view.KeyEvent
import com.termux.terminal.KeyHandler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Real synthetic coverage for the reused vendored parser + this lane's
 * input/renderer mapping — nothing here mocks the emulator: bytes go
 * through the actual pinned Termux terminal-emulator, and the assertions
 * check the resulting attributed screen state.
 */
class TerminalEngineTest {
    private class RecordingHost : TerminalEngineHost {
        var ptyWrites = ArrayList<ByteArray>()
        val logs = ArrayList<String>()
        override fun writeToPty(bytes: ByteArray) { ptyWrites.add(bytes) }
        override fun log(level: String, message: String) { logs.add("$level $message") }
    }

    private fun engine(columns: Int = 20, rows: Int = 5, host: RecordingHost = RecordingHost()) =
        G04TerminalEngine(columns, rows, host = host)

    private fun bytes(text: String) = text.toByteArray(Charsets.UTF_8)

    @Test
    fun plainTextAndWrappingParse() {
        val engine = engine()
        engine.feed(bytes("hello floe"))
        val screen = engine.visibleText()
        assertTrue("screen should contain typed text, got: $screen", screen.contains("hello floe"))
    }

    @Test
    fun utf8CjkAndWideCells() {
        val engine = engine(columns = 40)
        engine.feed(bytes("中文终端"))
        val text = engine.visibleText()
        assertTrue(text.contains("中文终端"))
        // CJK cells are double width: 4 chars occupy 8 columns; cursor after
        // the text sits at column 8 on a fresh line.
        engine.feed(bytes("X"))
        assertEquals(1, engine.cursorColumn() - 8)
    }

    @Test
    fun cursorAndControlSequences() {
        val engine = engine()
        engine.feed(bytes("ABCDEFGH"))
        engine.feed(bytes("\r\u001B[3C")) // CR then cursor right 3
        assertEquals(3, engine.cursorColumn())
        assertEquals(0, engine.cursorRow())
        engine.feed(bytes("\u001B[2;3H")) // absolute position row2 col3 (1-based)
        assertEquals(1, engine.cursorRow())
        assertEquals(2, engine.cursorColumn())
    }

    @Test
    fun ansiColorsAndBoldMapToStyles() {
        val engine = engine()
        engine.feed(bytes("\u001B[1;31mRED\u001B[0m normal"))
        // RED occupies row 0 columns 0..2; those cells must carry bold +
        // red foreground style bits, while the following plain cells reset.
        val redStyle = engine.emulatorForRender().getScreen().getStyleAt(0, 0)
        val redFore = com.termux.terminal.TextStyle.decodeForeColor(redStyle)
        val effects = com.termux.terminal.TextStyle.decodeEffect(redStyle)
        assertTrue("bold effect expected",
            effects and com.termux.terminal.TextStyle.CHARACTER_ATTRIBUTE_BOLD != 0)
        val plainStyle = engine.emulatorForRender().getScreen().getStyleAt(0, 10)
        val plainEffects = com.termux.terminal.TextStyle.decodeEffect(plainStyle)
        assertEquals(0, plainEffects and com.termux.terminal.TextStyle.CHARACTER_ATTRIBUTE_BOLD)
        assertNotEquals("red foreground must differ from the reset foreground",
            com.termux.terminal.TextStyle.decodeForeColor(plainStyle), redFore)
        assertNotEquals("styled cell must differ from reset cell", redStyle, plainStyle)
    }

    @Test
    fun selectionAndWordExtraction() {
        val engine = engine(columns = 30)
        engine.feed(bytes("alpha beta gamma"))
        val selection = engine.selectedText(6, 0, 9, 0)
        assertEquals("beta", selection)
        assertEquals("beta", engine.wordAt(7, 0))
    }

    @Test
    fun scrollbackTranscriptRows() {
        val engine = engine(columns = 20, rows = 3)
        // rows=3 clamps to MinimumRows=5: the first rows-1 linefeeds only
        // move the cursor and every later linefeed pushes exactly one real
        // row into the transcript, so ten fed rows accumulate just 6. Feed
        // past the clamped viewport (transcript = fed - (rows - 1) = 9) and
        // keep the original >=7 contract verbatim.
        for (line in 1..(engine.rows + 8)) {
            engine.feed(bytes("line$line\r\n"))
        }
        assertTrue("transcript must accumulate", engine.activeTranscriptRows() >= 7)
    }

    @Test
    fun resizeKeepsBoundsAndReportsAppliedGrid() {
        val engine = engine(columns = 20, rows = 3)
        val applied = engine.resizeTo(5000, 5000)
        assertEquals(G04TerminalEngine.MaximumColumns, applied.first)
        assertEquals(G04TerminalEngine.MaximumRows, applied.second)
        val small = engine.resizeTo(1, 1)
        assertEquals(G04TerminalEngine.MinimumColumns, small.first)
        assertEquals(G04TerminalEngine.MinimumRows, small.second)
    }

    @Test
    fun emulatorGeneratedResponsesRideOrderedPtyWrites() {
        val host = RecordingHost()
        val engine = engine(host = host)
        // Cursor position report request: the reused emulator must WRITE
        // the response bytes back through the host (external PTY proof).
        engine.feed(bytes("\u001B[6n"))
        assertTrue("DA1 request also answers; expect at least one ordered write",
            host.ptyWrites.isNotEmpty())
        val merged = host.ptyWrites.fold(ByteArray(0)) { acc, part -> acc + part }
        assertTrue("cursor report format ESC [ row ; col R",
            String(merged, Charsets.US_ASCII).matches(Regex("\u001B\\[\\d+;\\d+R")))
    }

    @Test
    fun bracketedPasteHonorsDecset2004() {
        val host = RecordingHost()
        val engine = engine(host = host)
        engine.feed(bytes("\u001B[?2004h"))
        host.ptyWrites.clear()
        engine.pasteText("one\r\ntwo")
        val merged = String(host.ptyWrites.fold(ByteArray(0)) { a, b -> a + b }, Charsets.UTF_8)
        assertTrue(merged.startsWith("\u001B[200~"))
        assertTrue(merged.endsWith("\u001B[201~"))
        // Upstream normalization: CRLF collapses to CR.
        assertTrue(merged.contains("one\rtwo"))
    }

    @Test
    fun utf8InputEncodingIsLosslessForCjk() {
        val encoded = TerminalInputEncoder.encodeText("中文ok😀")
        assertEquals("中文ok😀", String(encoded, Charsets.UTF_8))
        assertTrue(encoded.size > "中文ok😀".length)
    }

    @Test
    fun controlKeyEncodings() {
        // Encoders return ByteArray elements (boxed Byte on the JVM): compare
        // against Byte literals so the exact ETX/EOT/DEL proof asserts byte
        // equality instead of failing on Integer vs Byte boxing. Values are
        // unchanged.
        assertEquals(0x03.toByte(), TerminalInputEncoder.interrupt()[0])
        assertEquals(0x04.toByte(), TerminalInputEncoder.endOfFile()[0])
        assertEquals(0x7F.toByte(), TerminalInputEncoder.backspace()[0])
        val ctrlC = TerminalInputEncoder.encodeKey(
            KeyEvent.KEYCODE_C, ctrlDown = true, altDown = false, shiftDown = false,
            cursorKeysApplication = false, keypadApplication = false)
        assertEquals(0x03.toByte(), ctrlC!![0])
        val alt = TerminalInputEncoder.withAlt(byteArrayOf('x'.code.toByte()))
        assertEquals(0x1B.toByte(), alt[0])
        assertEquals('x'.code.toByte(), alt[1])
    }

    @Test
    fun arrowKeysFollowApplicationCursorModeViaReusedTables() {
        val normal = KeyHandler.getCode(KeyEvent.KEYCODE_DPAD_UP, 0, false, false)
        val app = KeyHandler.getCode(KeyEvent.KEYCODE_DPAD_UP, 0, true, false)
        assertEquals("\u001B[A", normal)
        assertEquals("\u001BOA", app)
        val encoded = TerminalInputEncoder.encodeKey(
            KeyEvent.KEYCODE_DPAD_UP, ctrlDown = false, altDown = false, shiftDown = false,
            cursorKeysApplication = true, keypadApplication = false)
        assertEquals("\u001BOA".toByteArray(Charsets.US_ASCII).toList(), encoded!!.toList())
    }

    @Test
    fun mouseTrackingModeObservedFromParser() {
        val engine = engine()
        assertFalse(engine.mouseTrackingActive())
        engine.feed(bytes("\u001B[?1000h"))
        assertTrue("button tracking DECSET must be visible to the renderer",
            engine.mouseTrackingActive())
        engine.feed(bytes("\u001B[?1000l"))
        assertFalse(engine.mouseTrackingActive())
    }

    @Test
    fun alternateBufferSwitchIsVisible() {
        val engine = engine()
        assertFalse(engine.emulatorForRender().isAlternateBufferActive)
        engine.feed(bytes("\u001B[?1049h"))
        assertTrue(engine.emulatorForRender().isAlternateBufferActive)
        engine.feed(bytes("\u001B[?1049l"))
        assertFalse(engine.emulatorForRender().isAlternateBufferActive)
    }

    @Test
    fun titleAndBellRouteToUiDelegate() {
        val engine = engine()
        var title = ""
        var bells = 0
        engine.ui = object : TerminalUiDelegate {
            override fun onTitleChanged(t: String) { title = t }
            override fun onBell() { bells += 1 }
            override fun onTextChanged() {}
            override fun onColorsChanged() {}
            override fun onCursorVisibilityChanged(visible: Boolean) {}
            override fun onProgramClipboardCopy(text: String) {}
            override fun requestProgramClipboardPaste(): String? = null
        }
        engine.feed(bytes("\u001B]0;Floe Task\u0007"))
        engine.feed(bytes("\u0007"))
        assertEquals("Floe Task", engine.title())
        assertEquals("Floe Task", title)
        assertEquals(1, bells)
    }
}
