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
}
