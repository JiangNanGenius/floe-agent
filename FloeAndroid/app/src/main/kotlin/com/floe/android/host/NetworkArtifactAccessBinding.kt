// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.host.networkartifact.NetworkArtifactAccess
import java.util.UUID

/**
 * The native tool dispatcher admits the file-read operation and derives the
 * principal from its real ToolContext; temporary/public-web calls never enter
 * this mailbox. This host-side gate checks that the current resource is still
 * explicitly exposed and belongs to that principal. UI holder presence is not
 * authority: background runs remain valid without an opened conversation view.
 */
internal fun networkArtifactAccessFor(
    currentNativeEpoch: () -> Long?,
): NetworkArtifactAccess = NetworkArtifactAccess { resource, caller ->
    val task = canonicalArtifactUUID(caller.taskID)
    val run = canonicalArtifactUUID(caller.runID)
    val artifact = canonicalArtifactUUID(resource.artifactID)
    val owner = resource.ownerTaskId?.let(::canonicalArtifactUUID)
    val workspace = resource.ownerWorkspaceId
    val callerWorkspace = caller.workspaceFingerprint
    resource.agentReadable && task != null && run != null && artifact != null &&
        caller.epoch > 0 && currentNativeEpoch() == caller.epoch &&
        (resource.ownerTaskId == null || owner == task) &&
        (workspace == null ||
            (workspace.matches(ARTIFACT_WORKSPACE_FINGERPRINT) &&
                callerWorkspace != null &&
                callerWorkspace.matches(ARTIFACT_WORKSPACE_FINGERPRINT) &&
                workspace.equals(callerWorkspace, ignoreCase = true)))
}

private val ARTIFACT_WORKSPACE_FINGERPRINT = Regex("[0-9a-fA-F]{64}")

private fun canonicalArtifactUUID(value: String): UUID? =
    runCatching { UUID.fromString(value) }.getOrNull()?.takeIf {
        it != UUID(0L, 0L) && it.toString().equals(value, ignoreCase = true)
    }
