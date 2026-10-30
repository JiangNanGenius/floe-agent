// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.terminalsessions

/**
 * The pane's ONE addressable target, derived from the tab registry without
 * touching any native/session state. This is the seam that decides which
 * engine, transport and snapshot the visible surface may use.
 */
internal data class TerminalPaneTarget(
    /** The exact native session identity, or null when none is addressable. */
    val sessionID: String?,
    /** The selected tab is a pending reservation with no native identity yet. */
    val pending: Boolean,
    /** No tabs exist at all: the pre-tab legacy conversation projection may be used. */
    val legacyConversation: Boolean,
)

/**
 * Pending/failed tabs must NEVER borrow another PTY. A tab with no native
 * identity is not addressable: [sessionID] stays null and the legacy
 * conversation fallback stays OFF even when another live tab exists. The
 * legacy projection is used ONLY when the conversation genuinely has no tabs
 * (the pre-tab compatibility path), exactly as the pane did before tabs.
 */
internal fun terminalPaneTarget(tabs: List<TerminalTabView>): TerminalPaneTarget {
    if (tabs.isEmpty()) {
        return TerminalPaneTarget(sessionID = null, pending = false, legacyConversation = true)
    }
    val selected = tabs.firstOrNull { it.selected } ?: tabs.lastOrNull()
    val sessionID = selected?.sessionID
    return TerminalPaneTarget(
        sessionID = sessionID,
        pending = sessionID == null,
        legacyConversation = false,
    )
}
