// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import android.view.View
import android.view.inputmethod.InputMethodManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * Keyboard ownership for surfaces that host a real editable (the terminal's
 * [com.floe.android.feature.terminal.TerminalImeProxy] EditText, composers,
 * document fields).
 *
 * Device evidence (Samsung SM-G9810, G07.3B QA, 2026-10-31): the soft
 * keyboard could stay visible after leaving the terminal, covering the
 * compact drawer bottom, and system Back navigated (or closed the inspector)
 * BEFORE the keyboard was dismissed.
 *
 * The policy is deliberately narrow and explicit:
 *  - System Back dismisses the IME FIRST, once, and does not navigate while
 *    the keyboard is visible. The next Back performs the surface's own back
 *    action. This is a decision made at the back event, never a blanket hide
 *    on recomposition.
 *  - A surface that owned the IME (the terminal pane) dismisses it when it
 *    actually leaves composition; opening the compact drawer dismisses it
 *    before the drawer is shown.
 *  - Dismissal clears the REAL focused view (the embedded EditText is not a
 *    Compose focus target) and then hides the window IME, so a detached
 *    terminal proxy cannot keep the keyboard above the next surface.
 */
internal enum class ImeBackDisposition { DISMISS_IME, INVOKE_BACK }

/**
 * Pure decision for a back event: while the IME is visible the first back is
 * ALWAYS the keyboard's own dismissal. Only a hidden IME reaches the
 * surface's navigation/close action. No handler state, no ordering race.
 */
internal fun imeBackDisposition(imeVisible: Boolean): ImeBackDisposition =
    if (imeVisible) ImeBackDisposition.DISMISS_IME else ImeBackDisposition.INVOKE_BACK

/**
 * Window-level IME dismissal. Clearing the focused view first is what makes
 * the embedded terminal EditText release the IME; hiding through the window
 * token then covers IMEs whose close animation was already in flight.
 */
internal fun dismissWindowIme(view: View) {
    val focused = view.rootView.findFocus()
    focused?.clearFocus()
    val manager = view.context.getSystemService(Context.INPUT_METHOD_SERVICE)
        as? InputMethodManager
    manager?.hideSoftInputFromWindow(view.windowToken, 0)
}

/** [dismissWindowIme] bound to the current Compose window root. */
@Composable
internal fun rememberImeDismissal(): () -> Unit {
    val view = LocalView.current
    return remember(view) { { dismissWindowIme(view) } }
}

/**
 * Back handler with IME-first semantics. Compose installs the LAST enabled
 * handler first in the dispatcher, so each surface that can host a keyboard
 * must use this wrapper instead of a raw [BackHandler]; the wrapper only
 * hides the IME and swallows that one event.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ImeFirstBackHandler(
    enabled: Boolean = true,
    onBack: () -> Unit,
) {
    val imeVisible = WindowInsets.isImeVisible
    val dismissIme = rememberImeDismissal()
    BackHandler(enabled = enabled) {
        when (imeBackDisposition(imeVisible)) {
            ImeBackDisposition.DISMISS_IME -> dismissIme()
            ImeBackDisposition.INVOKE_BACK -> onBack()
        }
    }
}
