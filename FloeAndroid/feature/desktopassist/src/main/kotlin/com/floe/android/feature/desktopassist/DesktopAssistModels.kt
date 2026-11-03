// SPDX-License-Identifier: MPL-2.0
//
// C05 Desktop Assist presentation values. Secret-free: card rows carry the
// stable reference and non-secret metadata only. The editor's one-time secret
// stays in the composable's RAM-only remember buffer and is never stored in
// this immutable state.

package com.floe.android.feature.desktopassist

/** One secure credential card (metadata only; no secret). */
data class DesktopAssistCardUi(
    val id: String,
    val reference: String,
    val label: String,
    val kind: String,
    val hostID: String?,
    val typingAllowed: Boolean,
    val updatedAtLabel: String?,
)

/** One remote-host profile the card may be scoped to. */
data class DesktopAssistHostUi(
    val id: String,
    val displayName: String,
    val address: String,
)

/** Nested card editor state; [cardID] null means create. */
data class DesktopAssistEditorUi(
    val editorID: String,
    val cardID: String?,
    val label: String,
    val kind: String,
    val hostID: String?,
    val hasExistingSecret: Boolean,
    val reference: String? = null,
)

enum class DesktopAssistNotice {
    SAVED,
    DELETED,
    INVALID,
    UNAVAILABLE,
}

data class DesktopAssistUiState(
    val loading: Boolean = false,
    val loaded: Boolean = false,
    val cards: List<DesktopAssistCardUi> = emptyList(),
    val hosts: List<DesktopAssistHostUi> = emptyList(),
    val linuxShellQualified: Boolean? = null,
    val editor: DesktopAssistEditorUi? = null,
    val saving: Boolean = false,
    val notice: DesktopAssistNotice? = null,
    val error: String? = null,
)

interface DesktopAssistActions {
    fun refresh()
    fun beginCreate()
    fun beginEdit(cardID: String)
    fun dismissEditor()
    fun save(editorID: String, label: String, kind: String, hostID: String?, secret: String?)
    fun delete(cardID: String)
    fun dismissNotice()
}

/** Card kinds the trusted resolver accepts for remote typing. */
object DesktopAssistKinds {
    const val WEBSITE_PASSWORD = "websitePassword"
    const val GENERIC_TOKEN = "genericToken"

    val all: List<String> = listOf(WEBSITE_PASSWORD, GENERIC_TOKEN)
}
