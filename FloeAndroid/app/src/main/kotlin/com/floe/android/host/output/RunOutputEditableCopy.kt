// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import com.floe.android.bridge.WorkspaceSourceNative
import com.floe.android.feature.conversation.RunOutputDisplayName
import com.floe.android.feature.conversation.RunOutputEditPresentation
import com.floe.android.host.G04WorkspaceBridgeClient
import com.floe.android.host.RuntimeHost
import com.floe.android.host.SourceHostReply
import java.io.File
import java.util.UUID
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Adopts sealed bytes as a separate workspace file before an editor gets write access. */
internal suspend fun createRunOutputEditableCopy(
    host: RuntimeHost,
    workspace: G04WorkspaceBridgeClient,
    owner: RunOutputOfficeSnapshotStager.Owner,
    extension: String,
    isCurrent: () -> Boolean,
): String {
    val stager = RunOutputOfficeSnapshotStager(
        File(host.appContext.cacheDir, "RunOutputEditableCopies"),
        NativeRunOutputChannel,
        formats = setOf(extension),
    )
    val snapshot = stager.stage(owner, isCurrent)
    try {
        val name = RunOutputDisplayName.facts(snapshot.displayName).transferName
        if (RunOutputEditPresentation.editableExtension(snapshot.mimeType, name, snapshot.bytes) != extension ||
            name.any { it == '/' || it == '\\' || it.code < 32 } || name.toByteArray().size > 255) {
            throw G04WorkspaceBridgeClient.Failure("invalidOutput")
        }
        val folder = "Edited Copies/${UUID.randomUUID()}"
        val pending = "$folder/.pending"
        val destination = "$folder/$name"
        return host.workspaceEditors.withExternalMutation(workspace.taskID) {
            if (!isCurrent()) throw G04WorkspaceBridgeClient.Failure("ownerChanged")
            // The unique empty stage is never the public copy. The existing
            // workspace CAS independently verifies the staged sealed bytes.
            val emptySHA = workspace.request("createFile", buildJsonObject { put("path", pending) })["sha256"]?.jsonPrimitive?.content
                ?: throw G04WorkspaceBridgeClient.Failure("copyNotVerified")
            if (!isCurrent()) throw G04WorkspaceBridgeClient.Failure("ownerChanged")
            val saved = SourceHostReply.call { reply ->
                WorkspaceSourceNative.saveOriginal(
                    owner.nativeEpoch, workspace.taskID, workspace.workspaceID, pending,
                    emptySHA, snapshot.sha256, snapshot.bytes, snapshot.file.path, reply,
                )
            }
            if (!saved.ok || saved.text("local") != "committed" ||
                saved.text("committedSHA256") != snapshot.sha256 || saved.number("committedBytes") != snapshot.bytes) {
                throw G04WorkspaceBridgeClient.Failure("copyNotVerified")
            }
            workspace.request("move", buildJsonObject { put("from", pending); put("to", destination) })
            val actual = workspace.request("metadata", buildJsonObject { put("path", destination) })
            if (actual["sha256"]?.jsonPrimitive?.content != snapshot.sha256 || actual["size"]?.jsonPrimitive?.longOrNull != snapshot.bytes ||
                actual["isSymlink"]?.jsonPrimitive?.booleanOrNull != false ||
                actual["isDirectory"]?.jsonPrimitive?.booleanOrNull != false) {
                throw G04WorkspaceBridgeClient.Failure("copyNotVerified")
            }
            destination
        }
    } finally {
        snapshot.file.delete()
        snapshot.file.parentFile?.delete()
    }
}
