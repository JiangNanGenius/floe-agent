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
    /** No tabs exist and this conversation never owned one: the pre-tab legacy
     *  conversation projection may be used. */
    val legacyConversation: Boolean,
    /** No tabs exist AFTER this conversation owned real native tabs: the pane
     *  must show its truthful empty state and offer a new tab. It must never
     *  resurrect the retired conversation/legacy projection (its old screen,
     *  status, fault or input belong to sessions that no longer exist). */
    val emptyAfterNativeTabs: Boolean,
)

/**
 * Pending/failed tabs must NEVER borrow another PTY. A tab with no native
 * identity is not addressable: [sessionID] stays null and the legacy
 * conversation fallback stays OFF even when another live tab exists. The
 * legacy projection is used ONLY when the conversation genuinely never had a
 * tab (the pre-tab compatibility path), exactly as the pane did before tabs.
 *
 * Once a conversation has owned at least one native tab, closing all of them
 * is an EMPTY TERMINAL, not a return to the pre-tab singleton: the last tab's
 * close settles that native session, so projecting the conversation snapshot
 * again would show a removed session's stale screen/fault.
 */
internal fun terminalPaneTarget(
    tabs: List<TerminalTabView>,
    hasNativeTabHistory: Boolean = false,
): TerminalPaneTarget {
    if (tabs.isEmpty()) {
        return TerminalPaneTarget(
            sessionID = null,
            pending = false,
            legacyConversation = !hasNativeTabHistory,
            emptyAfterNativeTabs = hasNativeTabHistory,
        )
    }
    val selected = tabs.firstOrNull { it.selected } ?: tabs.lastOrNull()
    val sessionID = selected?.sessionID
    return TerminalPaneTarget(
        sessionID = sessionID,
        pending = sessionID == null,
        legacyConversation = false,
        emptyAfterNativeTabs = false,
    )
}
