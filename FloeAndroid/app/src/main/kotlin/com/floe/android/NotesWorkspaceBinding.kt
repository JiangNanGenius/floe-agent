// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.feature.notes.ui.api.NotesHostPorts
import com.floe.android.feature.notes.ui.state.NotesWorkspaceSession
import com.floe.android.host.notesruntime.NotesAssistantHost

/** One App-owned editor and assistant binding, retained across navigation/rotation. */
internal data class NotesWorkspaceBinding(
    val ports: NotesHostPorts,
    val session: NotesWorkspaceSession,
    val assistant: NotesAssistantHost,
)
