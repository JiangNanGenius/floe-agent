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

    fun showKeyboard() {
        editText.isFocusableInTouchMode = true
        editText.requestFocus()
        val manager = editText.context.getSystemService(Context.INPUT_METHOD_SERVICE)
            as? InputMethodManager
        manager?.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
    }

    fun hideKeyboard() {
        val manager = editText.context.getSystemService(Context.INPUT_METHOD_SERVICE)
            as? InputMethodManager
        manager?.hideSoftInputFromWindow(editText.windowToken, 0)
    }

    fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val handled = sink.keyEvent(event)
        if (handled) editText.setText("")
        return handled
    }
}
