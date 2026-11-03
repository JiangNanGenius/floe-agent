// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench.ui.api

/**
 * Real task identity a media route was opened from.
 *
 * The document/media route already owns a real task/workspace; binding the
 * opened media project to that task must not create a second task or invent
 * a workspace. The library route has no owner context and may create a real
 * ordinary task only from the explicit Ask AI action.
 */
data class MediaAgentOwnerContext(
    val taskID: String,
    val workspaceID: String? = null,
)

/**
 * One explicit Ask AI request. [projectID]/[projectRevision] are the exact
 * project and revision the user is viewing; native re-reads and verifies both.
 * [instruction] is the user's optional text. It is carried into the task draft
 * after the trusted binding is recorded; it is never authority.
 */
data class MediaAgentTaskRequest(
    val projectID: String,
    val projectRevision: Long,
    val projectName: String,
    val ownerTaskID: String? = null,
    val ownerWorkspaceID: String? = null,
    val instruction: String = "",
    val selectionOpID: String,
)

/** The real task opened after the trusted association was recorded. */
data class MediaAgentTaskReceipt(
    val taskID: String,
    val bindingID: String,
)

/**
 * Bounded App failure code. The UI maps these to actionable copy; native
 * messages never contain paths, tokens or raw payloads.
 */
class MediaAgentBindingFailure(
    val code: String,
    message: String? = null,
) : Exception(message ?: code)

/**
 * App-owned explicit Ask AI seam. The implementation creates/opens a REAL
 * task through existing task services, asks the privileged native binding
 * issuer to associate the selected project with that task, and carries the
 * actual project reference into the task draft. Manual edits do not call it.
 */
interface MediaAgentBindingPort {
    suspend fun askAi(request: MediaAgentTaskRequest): MediaAgentTaskReceipt
}
