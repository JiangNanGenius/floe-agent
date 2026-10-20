// SPDX-License-Identifier: MPL-2.0
//
// Innermost-first back stack for the provider flow. "Back closes innermost
// model/catalog/menu -> editor -> settings" (contract): every pane this
// module owns is one stack entry; when the stack is empty the destination
// stops consuming system back and the host's existing settings-sheet
// BackHandler regains control (the wide settings column stays owned by the
// app shell — the module never pops it).

package com.floe.android.feature.providers

import androidx.compose.runtime.mutableStateListOf

/** Panes owned by this module, innermost-last. */
enum class ProviderPane {
    /** Root list inside the settings detail column (stack base). */
    LIST,

    /** Add-purpose chooser (⇄ confirmationDialog in ProviderListView; the
     * reference capture shows an anchored popover above the settings column). */
    ROLE_CHOOSER,

    /** Large grouped add/edit sheet (⇄ ProviderEditorView page sheet). */
    EDITOR,

    /** Unified supplier selector (⇄ anchored popover on iPad / sheet compact). */
    SUPPLIER_CHOOSER,

    /** Nested model manager pane (⇄ ModelPickerView sheet). */
    MODEL_MANAGER,

    /** Per-model settings sheet (⇄ ModelEditorView sheet). */
    MODEL_EDITOR,

    /** One-time multi-role prompt (⇄ ServiceOfferPromptSheet). */
    OFFER_PROMPT,
}

/** A stack entry keyed by pane + a caller-visible key (editorId / draftModelId). */
data class ProviderPaneEntry(val pane: ProviderPane, val key: String)

/**
 * Pure navigation state. The session holder owns one instance so config
 * changes keep the same innermost-first order; no Compose APIs here so the
 * ordering is unit-testable without a device.
 */
class ProviderNavStack {

    // Snapshot-state list: opening/closing a purely local pane (supplier
    // chooser, model manager, role chooser) must recompose the destination
    // immediately; a plain MutableList would only appear after an unrelated
    // host projection update.
    private val entries = mutableStateListOf(ProviderPaneEntry(ProviderPane.LIST, "list"))

    /** Snapshot for the destination to render panes base→top. */
    fun snapshot(): List<ProviderPaneEntry> = entries.toList()

    val top: ProviderPaneEntry get() = entries.last()

    val depth: Int get() = entries.size

    fun contains(pane: ProviderPane): Boolean = entries.any { it.pane == pane }

    fun entryFor(pane: ProviderPane): ProviderPaneEntry? = entries.lastOrNull { it.pane == pane }

    /** Push ignores duplicates of the same pane+key. */
    fun push(pane: ProviderPane, key: String) {
        if (entries.any { it.pane == pane && it.key == key }) return
        entries.add(ProviderPaneEntry(pane, key))
    }

    /** Pop the top pane only; the base LIST entry never pops (returns false
     * so the host settings sheet handles back). */
    fun back(): Boolean {
        if (entries.size <= 1) return false
        entries.removeAt(entries.lastIndex)
        return true
    }

    /** Close a named pane only when it is on top (explicit Cancel/Done). */
    fun closeTopIf(pane: ProviderPane, key: String): Boolean {
        if (entries.lastOrNull() == ProviderPaneEntry(pane, key)) {
            entries.removeAt(entries.lastIndex)
            return true
        }
        return false
    }

    /** Hard-close everything above LIST (leaving settings). */
    fun resetToBase() {
        entries.clear()
        entries.add(ProviderPaneEntry(ProviderPane.LIST, "list"))
    }
}
