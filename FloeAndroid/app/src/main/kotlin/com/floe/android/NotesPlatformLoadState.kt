// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.notesplatform.NotesPlatformHost

/** App-owned platform readiness; a failed initialization remains explicitly retryable. */
internal sealed interface NotesPlatformLoadState {
    data object Idle : NotesPlatformLoadState
    data object Loading : NotesPlatformLoadState
    data class Ready(val host: NotesPlatformHost, val workspace: NotesWorkspaceBinding) : NotesPlatformLoadState
    data object Failed : NotesPlatformLoadState
}
