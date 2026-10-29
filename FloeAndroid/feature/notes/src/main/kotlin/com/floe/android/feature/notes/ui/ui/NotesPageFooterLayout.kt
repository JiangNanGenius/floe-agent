// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

/**
 * The full page footer (paging, page count, zoom, page list, paper menu) is
 * about 520dp wide at the 48dp target floor. A phone, or the editor pane of
 * a medium two-column window, cannot fit it; rendering the full row there
 * pushed the trailing controls off-screen and squeezed the row's height.
 *
 * TIGHT keeps the essential, frequently used controls (previous / next /
 * page count / zoom out / zoom percent / zoom in) inside the viewport. Page
 * list and paper remain available in the editor's tool strip, so nothing is
 * lost on compact widths.
 */
internal enum class NotesPageFooterLayout { FULL, TIGHT }

internal fun notesPageFooterLayout(compact: Boolean, widthDp: Float): NotesPageFooterLayout =
    if (compact || widthDp < 560f) NotesPageFooterLayout.TIGHT else NotesPageFooterLayout.FULL
