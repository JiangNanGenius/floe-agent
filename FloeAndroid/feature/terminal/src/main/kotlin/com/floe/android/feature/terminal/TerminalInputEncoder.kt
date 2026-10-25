// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import android.view.KeyEvent
import com.termux.terminal.KeyHandler

/**
 * True terminal INPUT encoding: every user keystroke becomes real ordered
 * PTY bytes (never a local echo model). UTF-8 composed text (CJK included)
 * is encoded from the IME commit; physical keys route through the reused
 * Termux [KeyHandler] tables so arrow/application-cursor/keypad modes,
 * function keys and modifier combinations match a real terminal.
 *
 * Ctrl-C is deliberately NOT special-cased here: on a PTY the ETX byte is
 * line-discipline input raised as SIGINT for the foreground group — it is
 * encoded like any other control combo, in order, exactly as the ORIGINAL
 * iOS terminal owner documents.
 */
object TerminalInputEncoder {

    /** Composed/committed IME text (UTF-8, lossless for CJK and emoji). */
    fun encodeText(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    /** Enter key: CR — the line discipline turns it into a newline only
     * when ONLCR wants; interactive shells expect CR. */
    fun enter(): ByteArray = byteArrayOf(0x0D)

    /** Backspace: the ORIGINAL terminal convention is DEL (0x7F). */
    fun backspace(): ByteArray = byteArrayOf(0x7F)

    /** Tab. */
    fun tab(): ByteArray = byteArrayOf(0x09)

    /** Escape. */
    fun escape(): ByteArray = byteArrayOf(0x1B)

    /** The interrupt key byte, ordered input (see class docs). */
    fun interrupt(): ByteArray = byteArrayOf(0x03)

    /** End-of-input for the PTY line discipline (interactive Ctrl-D). */
    fun endOfFile(): ByteArray = byteArrayOf(0x04)

    /** Alt as the ESC prefix (xterm meta behavior, the iOS parity choice). */
    fun withAlt(bytes: ByteArray): ByteArray = byteArrayOf(0x1B) + bytes

    /**
     * Pure key mapping (unit-testable): Android keyCode + modifier flags ->
     * terminal control bytes using the reused Termux [KeyHandler] tables
     * (arrow/home/end/pgup/pgdn/ins/del/F1-F12 with the CURRENT
     * application-mode flags), plus the classic control combos. Returns
     * null when no terminal bytes exist for the key.
     */
    fun encodeKey(
        keyCode: Int,
        ctrlDown: Boolean,
        altDown: Boolean,
        shiftDown: Boolean,
        cursorKeysApplication: Boolean,
        keypadApplication: Boolean,
    ): ByteArray? {
        // Ctrl + letter/symbol: the classic control byte.
        if (ctrlDown && !altDown) {
            when (keyCode) {
                android.view.KeyEvent.KEYCODE_A -> return byteArrayOf(0x01)
                android.view.KeyEvent.KEYCODE_B -> return byteArrayOf(0x02)
                android.view.KeyEvent.KEYCODE_C -> return byteArrayOf(0x03)
                android.view.KeyEvent.KEYCODE_D -> return byteArrayOf(0x04)
                android.view.KeyEvent.KEYCODE_E -> return byteArrayOf(0x05)
                android.view.KeyEvent.KEYCODE_F -> return byteArrayOf(0x06)
                android.view.KeyEvent.KEYCODE_G -> return byteArrayOf(0x07)
                // KEYCODE_H is the terminal backspace convention under Ctrl.
                android.view.KeyEvent.KEYCODE_H -> return byteArrayOf(0x08)
                android.view.KeyEvent.KEYCODE_I -> return byteArrayOf(0x09)
                android.view.KeyEvent.KEYCODE_J -> return byteArrayOf(0x0A)
                android.view.KeyEvent.KEYCODE_K -> return byteArrayOf(0x0B)
                android.view.KeyEvent.KEYCODE_L -> return byteArrayOf(0x0C)
                android.view.KeyEvent.KEYCODE_M -> return byteArrayOf(0x0D)
                android.view.KeyEvent.KEYCODE_N -> return byteArrayOf(0x0E)
                android.view.KeyEvent.KEYCODE_O -> return byteArrayOf(0x0F)
                android.view.KeyEvent.KEYCODE_P -> return byteArrayOf(0x10)
                android.view.KeyEvent.KEYCODE_Q -> return byteArrayOf(0x11)
                android.view.KeyEvent.KEYCODE_R -> return byteArrayOf(0x12)
                android.view.KeyEvent.KEYCODE_S -> return byteArrayOf(0x13)
                android.view.KeyEvent.KEYCODE_T -> return byteArrayOf(0x14)
                android.view.KeyEvent.KEYCODE_U -> return byteArrayOf(0x15)
                android.view.KeyEvent.KEYCODE_V -> return byteArrayOf(0x16)
                android.view.KeyEvent.KEYCODE_W -> return byteArrayOf(0x17)
                android.view.KeyEvent.KEYCODE_X -> return byteArrayOf(0x18)
                android.view.KeyEvent.KEYCODE_Y -> return byteArrayOf(0x19)
                android.view.KeyEvent.KEYCODE_Z -> return byteArrayOf(0x1A)
            }
        }
        var keyMode = 0
        if (altDown) keyMode = keyMode or KeyHandler.KEYMOD_ALT
        if (ctrlDown) keyMode = keyMode or KeyHandler.KEYMOD_CTRL
        if (shiftDown) keyMode = keyMode or KeyHandler.KEYMOD_SHIFT
        val code = KeyHandler.getCode(keyCode, keyMode, cursorKeysApplication, keypadApplication)
        if (code != null) return code.toByteArray(Charsets.US_ASCII)
        return when (keyCode) {
            android.view.KeyEvent.KEYCODE_ENTER -> enter()
            android.view.KeyEvent.KEYCODE_TAB -> tab()
            android.view.KeyEvent.KEYCODE_DEL -> backspace()
            android.view.KeyEvent.KEYCODE_ESCAPE -> escape()
            else -> null
        }
    }

    /**
     * A hardware key event's produced unicode character -> UTF-8 PTY bytes.
     *
     * ACTUAL AOSP contract (verified against frameworks/base
     * `KeyEvent.getUnicodeChar(metaState)` -> `KeyCharacterMap.get(keyCode,
     * metaState)`): the answer is 0 when the key types nothing, otherwise a
     * Unicode scalar, and the ONLY extra flag is bit 0x80000000
     * (`KeyCharacterMap.COMBINING_ACCENT`) marking a "dead key" accent that
     * must be combined with another key and never be sent alone. There is
     * no other high-half-word flag: everything through U+10FFFF is a valid
     * printable scalar — Latin-1, CJK, and the SUPPLEMENTARY planes
     * (U+1F600, U+20000, U+10070 …), encoded here as lossless UTF-8.
     * Isolated surrogates (0xD800–0xDFFF) cannot encode, and every control
     * character stays on the [encodeKey] keycode path. Termux upstream does
     * the same: KeyHandler tables first, then `getUnicodeChar` for text.
     *
     * (Review correction: an earlier draft rejected everything ≥0x10000 as
     * "flag composites", which wrongly refused valid supplementary-plane
     * scalars; the only real flag is COMBINING_ACCENT above bit 30.)
     */
    fun encodeUnicodeChar(unicodeChar: Int): ByteArray? {
        // 0 = nothing typed; COMBINING_ACCENT (bit 31) makes the value
        // negative: a dead-key accent alone is never printable text.
        if (unicodeChar <= 0) return null
        // Beyond the Unicode range, or an isolated surrogate half.
        if (unicodeChar > 0x10FFFF || unicodeChar in 0xD800..0xDFFF) return null
        // Controls (incl. DEL 0x7F and C1) belong to the keycode/control
        // mapping, never a raw "character".
        if (Character.isISOControl(unicodeChar)) return null
        return String(Character.toChars(unicodeChar)).toByteArray(Charsets.UTF_8)
    }

    /**
     * Physical key event -> bytes using the reused Termux KeyHandler tables
     * with the emulator's CURRENT application-mode flags.
     */
    fun encodeKeyEvent(
        event: android.view.KeyEvent,
        cursorKeysApplication: Boolean,
        keypadApplication: Boolean,
    ): ByteArray? {
        if (event.action != android.view.KeyEvent.ACTION_DOWN) return null
        return encodeKey(
            keyCode = event.keyCode,
            ctrlDown = event.isCtrlPressed,
            altDown = event.isAltPressed,
            shiftDown = event.isShiftPressed,
            cursorKeysApplication = cursorKeysApplication,
            keypadApplication = keypadApplication,
        )
    }

    /**
     * HARDWARE key event -> PTY bytes. `adb shell input text`, an external
     * keyboard and injected physical keys all arrive here as key events
     * (not IME commits): without the unicode fallback printable characters
     * fell through to the focused view and were retained in the hidden
     * EditText instead of reaching the PTY.
     *
     * The whole decision is factored into the pure [encodePhysicalKey]
     * core; this overload reads the platform event exactly the way the
     * core documents (`getUnicodeChar(metaState)` applies the current
     * shift/alt/dead layouting and is the ONLY producer of the
     * COMBINING_ACCENT-flagged value).
     */
    fun encodePhysicalKeyEvent(
        event: android.view.KeyEvent,
        cursorKeysApplication: Boolean,
        keypadApplication: Boolean,
    ): ByteArray? {
        if (event.action != android.view.KeyEvent.ACTION_DOWN) return null
        return encodePhysicalKey(
            keyCode = event.keyCode,
            ctrlDown = event.isCtrlPressed,
            altDown = event.isAltPressed,
            shiftDown = event.isShiftPressed,
            unicodeChar = event.getUnicodeChar(event.metaState),
            cursorKeysApplication = cursorKeysApplication,
            keypadApplication = keypadApplication,
        )
    }

    /**
     * PURE hardware-key decision (unit-testable without a framework
     * KeyEvent):
     *  * Android system BACK is NEVER a PTY byte: it keeps its platform
     *    meaning inside the pane (close the IME / navigate back). The
     *    vendored KeyHandler maps KEYCODE_BACK to ESC for legacy phone
     *    keyboards, and the dedicated hardware KEYCODE_ESCAPE still sends
     *    PTY ESC through [encodeKey].
     *  * KeyHandler/control combos first, unchanged ([encodeKey]).
     *  * Ctrl combos that [encodeKey] does not own stay refused — the
     *    unicode fallback never fabricates a plain char under Ctrl.
     *  * Alt + printable reuses the xterm "meta sends ESC" form
     *    ([withAlt]) — exactly how KeyHandler's alt special keys behave —
     *    instead of dropping legitimate Alt letters.
     *  * Everything else falls back to the produced printable scalar.
     */
    fun encodePhysicalKey(
        keyCode: Int,
        ctrlDown: Boolean,
        altDown: Boolean,
        shiftDown: Boolean,
        unicodeChar: Int,
        cursorKeysApplication: Boolean,
        keypadApplication: Boolean,
    ): ByteArray? {
        if (keyCode == android.view.KeyEvent.KEYCODE_BACK) return null
        val mapped = encodeKey(
            keyCode = keyCode,
            ctrlDown = ctrlDown,
            altDown = altDown,
            shiftDown = shiftDown,
            cursorKeysApplication = cursorKeysApplication,
            keypadApplication = keypadApplication,
        )
        if (mapped != null) return mapped
        if (ctrlDown) return null
        val printable = encodeUnicodeChar(unicodeChar) ?: return null
        return if (altDown) withAlt(printable) else printable
    }
}
