// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure-JVM regression for the HARDWARE key path (external keyboard and
 * injected physical key events, e.g. `adb shell input text`).
 *
 * The original failure: printable keys have no Termux [com.termux.terminal.KeyHandler]
 * mapping (letters/digits/punctuation are IME-commit territory upstream),
 * so `encodeKeyEvent` returned null for them, the focused proxy view fell
 * back to default EditText handling and RETAINED the typed command, and
 * nothing ever reached the PTY. The repair adds the
 * `KeyEvent.getUnicodeChar` text fallback (exactly the upstream Termux
 * TerminalView principle: KeyHandler tables first, then the produced
 * unicode char) plus the Main review corrections:
 *  * the unicode filter accepts EVERY valid scalar through U+10FFFF
 *    (supplementary planes included) and refuses only the real
 *    [android.view.KeyCharacterMap] COMBINING_ACCENT (bit 0x80000000)
 *    dead-key composite, isolated surrogates and controls;
 *  * Android system BACK is never a PTY byte on the hardware path while
 *    the dedicated KEYCODE_ESCAPE still sends ESC;
 *  * Alt + printable reuses the xterm ESC-prefix form instead of being
 *    dropped.
 *
 * KeyEvent itself is a framework stub under JVM unit tests (no field
 * setting constructors), so this file drives the PURE cores
 * [TerminalInputEncoder.encodeKey], [TerminalInputEncoder.encodeUnicodeChar]
 * and [TerminalInputEncoder.encodePhysicalKey], which
 * [TerminalInputEncoder.encodePhysicalKeyEvent] composes verbatim from
 * `event.keyCode/isCtrlPressed/isAltPressed/isShiftPressed`,
 * `event.getUnicodeChar(event.metaState)` and the application-mode flags.
 */
class TerminalHardwareInputTest {

    private fun bytes(text: String) = text.toByteArray(Charsets.UTF_8)

    /* ---- the missing coverage that caused the retained-EditText bug ---- */

    @Test
    fun plainLettersHaveNoKeyHandlerMappingSoTheUnicodeFallbackIsRequired() {
        // Documents the exact gap: KeyHandler returns null for P/W/D.
        assertNull(TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_P, false, false, false, false, false))
        assertNull(TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_W, false, false, false, false, false))
        assertNull(TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_D, false, false, false, false, false))
        // ...while the physical encoder turns the produced chars into bytes.
        assertArrayEquals(bytes("p"), TerminalInputEncoder.encodeUnicodeChar('p'.code))
        assertArrayEquals(bytes("w"), TerminalInputEncoder.encodeUnicodeChar('w'.code))
        assertArrayEquals(bytes("d"), TerminalInputEncoder.encodeUnicodeChar('d'.code))
    }

    @Test
    fun printableUnicodeEncodesUtf8Lossless() {
        assertArrayEquals(bytes(" "), TerminalInputEncoder.encodeUnicodeChar(' '.code))
        assertArrayEquals(bytes("1"), TerminalInputEncoder.encodeUnicodeChar('1'.code))
        // Shift/layout is applied by getUnicodeChar upstream of this filter.
        assertArrayEquals(bytes("P"), TerminalInputEncoder.encodeUnicodeChar('P'.code))
        assertArrayEquals(bytes("/"), TerminalInputEncoder.encodeUnicodeChar('/'.code))
        // CJK layout keyboards deliver code points above Latin-1: still lossless.
        assertArrayEquals(bytes("中"), TerminalInputEncoder.encodeUnicodeChar(0x4E2D))
        assertArrayEquals(bytes("é"), TerminalInputEncoder.encodeUnicodeChar(0xE9))
    }

    @Test
    fun validSupplementaryScalarsArePrintableTextNotFlagComposites() {
        // Review correction: an earlier draft asserted `0x10000 or 'p'`
        // (a "flag composite") to be refused. That value is U+10070 — a
        // perfectly valid printable scalar (Linear B syllable) — and
        // rejecting everything >= 0x10000 also refused emoji (U+1F600)
        // and CJK Extension B (U+20000). The verified AOSP contract:
        // KeyEvent.getUnicodeChar(metaState) == KeyCharacterMap.get(...),
        // whose ONLY extra flag is COMBINING_ACCENT (bit 31, 0x80000000).
        assertNotNull(TerminalInputEncoder.encodeUnicodeChar(0x10000 or 'p'.code))
        assertArrayEquals(bytes("\uD800\uDC70"),
            TerminalInputEncoder.encodeUnicodeChar(0x10070))
        assertArrayEquals(bytes("😀"), TerminalInputEncoder.encodeUnicodeChar(0x1F600))
        assertArrayEquals(bytes("\uD840\uDC00"),
            TerminalInputEncoder.encodeUnicodeChar(0x20000))
        // The largest valid scalar stays inside the range.
        assertNotNull(TerminalInputEncoder.encodeUnicodeChar(0x10FFFF))
    }

    @Test
    fun controlSurrogateAndDeadKeyCompositesStayRefused() {
        // Controls belong to the KeyHandler/control mapping (or produce no
        // char at all), never a raw "character": this keeps Ctrl/Enter/TAB
        // ordering single-sourced.
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(-1))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x03)) // Ctrl-C byte
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x09)) // TAB
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x0D)) // CR
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x7F)) // DEL
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x1B)) // ESC
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x9F)) // C1 control
        // The ACTUAL KeyCharacterMap flag: COMBINING_ACCENT (0x80000000)
        // marks a "dead key" that must be combined, never sent alone.
        // Masked in (bit 31 set) the Int is negative — refused.
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x80000000.toInt()))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x80000000.toInt() or 'a'.code))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(Int.MIN_VALUE or 0x300))
        // Out of the Unicode range, and isolated surrogate halves.
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x110000))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0x7FFFFFFF))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0xD800))
        assertNull(TerminalInputEncoder.encodeUnicodeChar(0xDFFF))
    }

    /* ---- the pure hardware-key core (system-UI + combos contract) ---- */

    @Test
    fun androidSystemBackStaysPlatformOwnedWhileEscapeSendsPtyEsc() {
        // The vendored KeyHandler still maps legacy BACK to ESC…
        assertArrayEquals(bytes("\u001B"), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_BACK, false, false, false, false, false))
        // …but the HARDWARE path must not trap it: KEYCODE_BACK keeps its
        // platform meaning (close the IME / navigate back inside the pane).
        assertNull(TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_BACK, false, false, false, 0, false, false))
        // The dedicated hardware Escape key still sends PTY ESC.
        assertArrayEquals(byteArrayOf(0x1B), TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_ESCAPE, false, false, false, 0, false, false))
    }

    @Test
    fun altPrintableReusesTheEscPrefixInsteadOfBeingDropped() {
        // xterm "meta sends ESC" — exactly how KeyHandler's alt special
        // keys behave — instead of refusing legitimate Alt letters.
        val x = 'x'.code
        assertArrayEquals(TerminalInputEncoder.withAlt(bytes("x")),
            TerminalInputEncoder.encodePhysicalKey(
                android.view.KeyEvent.KEYCODE_X, false, true, false, x, false, false))
        assertArrayEquals(bytes("x"), TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_X, false, false, false, x, false, false))
        // A special key that KeyHandler owns under Alt keeps its table
        // sequence (the fallback must not double-handle it).
        val tableSeq = TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_DPAD_UP, false, true, false, false, false)
        assertNotNull(tableSeq)
        assertArrayEquals(tableSeq, TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_DPAD_UP, false, true, false, 'x'.code, false, false))
    }

    @Test
    fun ctrlCombosStayOnTheKeycodePathAndUnmappedKeysAreRefusedHonestly() {
        // Ctrl+C is owned by the classic control mapping.
        assertArrayEquals(byteArrayOf(0x03), TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_C, true, false, false, 'c'.code, false, false))
        // Ctrl+P keeps the ORIGINAL mapping (DLE) — the unicode payload
        // must not override it.
        assertArrayEquals(byteArrayOf(0x10), TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_P, true, false, false, 'p'.code, false, false))
        // A Ctrl combo the mapping does NOT own must never fabricate the
        // plain character (a silent wrong keystroke); it stays refused.
        assertNull(TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_COMMA, true, false, false, ','.code, false, false))
        // An unmapped key with no printable char produces nothing.
        assertNull(TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_UNKNOWN, false, false, false, 0, false, false))
        // Plain printable flows through the core.
        assertArrayEquals(bytes("p"), TerminalInputEncoder.encodePhysicalKey(
            android.view.KeyEvent.KEYCODE_P, false, false, false, 'p'.code, false, false))
    }

    /* ---- the reused KeyHandler semantics must stay unchanged ---- */

    @Test
    fun specialKeysStillRouteThroughTheKeyHandlerTables() {
        assertArrayEquals(bytes("\u001B[A"), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_DPAD_UP, false, false, false, false, false))
        assertArrayEquals(bytes("\u001BOB"), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_DPAD_DOWN, false, false, false, true, false))
        assertArrayEquals(byteArrayOf(0x0D), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_ENTER, false, false, false, false, false))
        assertArrayEquals(byteArrayOf(0x09), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_TAB, false, false, false, false, false))
        assertArrayEquals(byteArrayOf(0x7F), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_DEL, false, false, false, false, false))
        assertArrayEquals(byteArrayOf(0x03), TerminalInputEncoder.encodeKey(
            android.view.KeyEvent.KEYCODE_C, true, false, false, false, false))
    }

    @Test
    fun compositionEncodingIsUntouchedUtf8() {
        // IME commit path semantics unchanged: text arrives lossless UTF-8.
        assertArrayEquals(bytes("中文pwd"), TerminalInputEncoder.encodeText("中文pwd"))
        assertEquals(0x0D.toByte(), TerminalInputEncoder.enter().single())
    }
}
