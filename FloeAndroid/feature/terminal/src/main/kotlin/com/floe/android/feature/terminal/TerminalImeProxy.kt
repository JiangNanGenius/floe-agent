// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.terminal

import android.content.Context
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.EditText

/**
 * True terminal IME input over a real Android [InputConnection]: committed
 * text (UTF-8, CJK included — never a local model echo) goes straight to
 * the PTY as ordered bytes; the composing (candidate) region is NEVER
 * emitted until it is finalized, so Chinese/Japanese input commits exactly
 * once each; IME key events (Enter/Backspace/Arrows…) are encoded through
 * the reused Termux [com.termux.terminal.KeyHandler] semantics.
 *
 * The proxy deliberately does NOT persist text in the EditText: after each
 * commit the editable stays empty, so the projection can never become a
 * second (shadow) document. The pane owns only keystrokes in and bytes out.
 */
class TerminalImeProxy(
    context: Context,
    private val sink: TerminalImeSink,
) {
    interface TerminalImeSink {
        /** Final composed/committed text: encode UTF-8 to the PTY now. */
        fun commitText(text: String)
        /** A key event; return true when terminal bytes were produced. */
        fun keyEvent(event: KeyEvent): Boolean
    }

    private val editText = object : EditText(context) {
        init {
            // TextView exposes these two as setter-only Java methods (no
            // getter), so they are called directly; no property exists.
            setHorizontallyScrolling(false)
            setSelectAllOnFocus(false)
            setText("")
            isCursorVisible = false
            setBackgroundColor(0x00000000)
        }

        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection =
            Connection(this, true, sink)

        /** HARDWARE keys. An external keyboard and injected physical key
         * events (including `adb shell input text`) are dispatched to the
         * FOCUSED view — this proxy — not through the InputConnection.
         * Route them through the terminal sink first (special keys via the
         * reused KeyHandler tables, printable keys via the event's unicode
         * char); only an unowned event may reach the default EditText
         * handling, so the editable can never retain typed commands.
         *
         * Android system BACK is platform-owned: it must close the IME /
         * navigate back, never become PTY ESC (the dedicated hardware
         * KEYCODE_ESCAPE is what sends ESC). Both its DOWN and its UP
         * bypass the sink entirely, so the platform back/long-press
         * tracking keeps its complete event pair. */
        override fun dispatchKeyEvent(event: KeyEvent): Boolean {
            if (event.keyCode == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
            if (this@TerminalImeProxy.dispatchKeyEvent(event)) return true
            return super.dispatchKeyEvent(event)
        }
    }

    private class Connection(
        private val view: EditText,
        finishComposingTextBehavior: Boolean,
        private val sink: TerminalImeSink,
    ) : BaseInputConnection(view, finishComposingTextBehavior) {

        /** The currently composing candidate text; bytes are withheld
         * until finishComposingText()/commitText(). */
        private var composing: String = ""

        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
            val value = text?.toString().orEmpty()
            if (value.isNotEmpty()) sink.commitText(value)
            composing = ""
            view.setText("")
            return true
        }

        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
            composing = text?.toString().orEmpty()
            // Show nothing in the proxy (the PTY is the display).
            view.setText("")
            return true
        }

        override fun finishComposingText(): Boolean {
            if (composing.isNotEmpty()) {
                sink.commitText(composing)
                composing = ""
            }
            view.setText("")
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (composing.isNotEmpty() &&
                event.action == KeyEvent.ACTION_DOWN &&
                event.keyCode == KeyEvent.KEYCODE_ENTER) {
                // Some IMEs finalize by sending Enter: flush first.
                sink.commitText(composing)
                composing = ""
            }
            val handled = sink.keyEvent(event)
            view.setText("")
            return handled
        }

        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            // A soft keyboard backspace arrives here with an empty proxy:
            // route it to the real terminal DEL bytes via the sink.
            if (beforeLength > 0 && view.text.length == 0) {
                sink.keyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL))
                sink.keyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL))
                return true
            }
            return super.deleteSurroundingText(beforeLength, afterLength)
        }

        override fun performEditorAction(actionCode: Int): Boolean {
            if (actionCode == EditorInfo.IME_ACTION_SEND || actionCode == EditorInfo.IME_ACTION_GO) {
                sink.keyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                sink.keyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                return true
            }
            return super.performEditorAction(actionCode)
        }
    }

    val view: View get() = editText

    /** Whether THIS proxy currently owns a keyboard-show request. A later
     * hide/dispose clears it, so a stale posted request cannot steal focus. */
    private var keyboardRequested = false

    private val focusRunnable = Runnable {
        if (!keyboardRequested) return@Runnable
        if (!editText.isAttachedToWindow) return@Runnable
        // The first request can run before the Compose AndroidView is
        // attached/focusable (the terminal pane is opened while the composer
        // still owns the IME). Re-assert focus after attachment instead of
        // assuming the synchronous requestFocus() worked.
        if (!editText.isFocused) editText.requestFocus()
        if (!editText.isFocused) return@Runnable
        val manager = editText.context.getSystemService(Context.INPUT_METHOD_SERVICE)
            as? InputMethodManager
        manager?.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
    }

    fun showKeyboard() {
        keyboardRequested = true
        editText.isFocusable = true
        editText.isFocusableInTouchMode = true
        setShowSoftInputOnFocus(true)
        editText.requestFocus()
        editText.removeCallbacks(focusRunnable)
        editText.post(focusRunnable)
    }

    fun hideKeyboard() {
        keyboardRequested = false
        editText.removeCallbacks(focusRunnable)
        val manager = editText.context.getSystemService(Context.INPUT_METHOD_SERVICE)
            as? InputMethodManager
        manager?.hideSoftInputFromWindow(editText.windowToken, 0)
    }

    /** Pane/engine teardown fence: a focus request posted by this proxy must
     * never run against a later tab, conversation or detached AndroidView. */
    fun dispose() {
        keyboardRequested = false
        editText.removeCallbacks(focusRunnable)
    }

    private fun setShowSoftInputOnFocus(enabled: Boolean) {
        // TextView exposes this as a setter-only method (no Kotlin property).
        editText.setShowSoftInputOnFocus(enabled)
    }

    /** keyCode whose hardware DOWN the terminal actually owned (0 = none),
     * so the matching UP is consumed only as its pair. Without this an
     * unowned key's UP would be swallowed here and break the platform's
     * long-press/back tracking that needs the complete unhandled pair. */
    private var hardwareDownCode = 0

    fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val handled = when (event.action) {
            KeyEvent.ACTION_DOWN ->
                sink.keyEvent(event).also { hardwareDownCode = if (it) event.keyCode else 0 }
            KeyEvent.ACTION_MULTIPLE ->
                // Batch-injected text (characters payload, no DOWN/UP pair).
                sink.keyEvent(event)
            else ->
                if (event.keyCode == hardwareDownCode && hardwareDownCode != 0) {
                    hardwareDownCode = 0
                    true
                } else false
        }
        if (handled) editText.setText("")
        return handled
    }
}
