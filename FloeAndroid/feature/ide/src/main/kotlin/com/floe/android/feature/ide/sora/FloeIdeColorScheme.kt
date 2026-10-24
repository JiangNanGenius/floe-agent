// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.sora

import io.github.rosemoe.sora.widget.schemes.EditorColorScheme

/**
 * Maps the Floe semantic palette (sampled from the iPad build) onto Sora
 * [EditorColorScheme] slots so the native editor renders inside the existing
 * iOS/iPad world — never the default Material/scheme styling. All colors are
 * ARGB integers converted from the Compose palette by the UI layer.
 */
public data class FloeEditorRoles(
    val windowBackground: Int,
    val textNormal: Int,
    val secondaryLabel: Int,
    val lineNumber: Int,
    val lineNumberBackground: Int,
    val accent: Int,
    val selectionBackground: Int,
    val currentLine: Int,
    val separator: Int,
    val success: Int,
    val destructive: Int,
    val pending: Int,
)

public fun floeEditorScheme(roles: FloeEditorRoles): EditorColorScheme {
    val scheme = EditorColorScheme()
    scheme.apply {
        setColor(EditorColorScheme.WHOLE_BACKGROUND, roles.windowBackground)
        setColor(EditorColorScheme.TEXT_NORMAL, roles.textNormal)
        setColor(EditorColorScheme.LINE_NUMBER, roles.lineNumber)
        setColor(EditorColorScheme.LINE_NUMBER_BACKGROUND, roles.lineNumberBackground)
        setColor(EditorColorScheme.LINE_NUMBER_PANEL, roles.lineNumberBackground)
        setColor(EditorColorScheme.LINE_NUMBER_PANEL_TEXT, roles.secondaryLabel)
        setColor(EditorColorScheme.LINE_NUMBER_CURRENT, roles.textNormal)
        setColor(EditorColorScheme.LINE_DIVIDER, roles.separator)
        setColor(EditorColorScheme.SELECTED_TEXT_BACKGROUND, roles.selectionBackground)
        setColor(EditorColorScheme.SELECTION_HANDLE, roles.accent)
        setColor(EditorColorScheme.SELECTION_INSERT, roles.accent)
        setColor(EditorColorScheme.CURRENT_LINE, roles.currentLine)
        setColor(EditorColorScheme.SCROLL_BAR_THUMB, roles.secondaryLabel)
        setColor(EditorColorScheme.SCROLL_BAR_TRACK, roles.windowBackground)
        setColor(EditorColorScheme.KEYWORD, roles.accent)
        setColor(EditorColorScheme.COMMENT, roles.secondaryLabel)
        setColor(EditorColorScheme.LITERAL, roles.success)
        setColor(EditorColorScheme.OPERATOR, roles.pending)
        setColor(EditorColorScheme.IDENTIFIER_NAME, roles.textNormal)
        setColor(EditorColorScheme.IDENTIFIER_VAR, roles.textNormal)
        setColor(EditorColorScheme.FUNCTION_NAME, roles.textNormal)
        setColor(EditorColorScheme.ANNOTATION, roles.pending)
        setColor(EditorColorScheme.PROBLEM_ERROR, roles.destructive)
        setColor(EditorColorScheme.PROBLEM_WARNING, roles.pending)
        setColor(EditorColorScheme.PROBLEM_TYPO, roles.secondaryLabel)
        setColor(EditorColorScheme.UNDERLINE, roles.destructive)
        setColor(EditorColorScheme.COMPLETION_WND_BACKGROUND, roles.windowBackground)
        setColor(EditorColorScheme.COMPLETION_WND_ITEM_CURRENT, roles.currentLine)
        setColor(EditorColorScheme.COMPLETION_WND_TEXT_PRIMARY, roles.textNormal)
        setColor(EditorColorScheme.COMPLETION_WND_TEXT_SECONDARY, roles.secondaryLabel)
        setColor(EditorColorScheme.COMPLETION_WND_CORNER, roles.windowBackground)
        setColor(EditorColorScheme.DIAGNOSTIC_TOOLTIP_BACKGROUND, roles.windowBackground)
        setColor(EditorColorScheme.DIAGNOSTIC_TOOLTIP_BRIEF_MSG, roles.textNormal)
        setColor(EditorColorScheme.DIAGNOSTIC_TOOLTIP_DETAILED_MSG, roles.secondaryLabel)
    }
    return scheme
}
