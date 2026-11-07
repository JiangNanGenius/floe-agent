// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import java.util.UUID

/** Navigation context only. The existing native bindExisting and document
 * stagers still resolve ownership and file containment after every restart. */
internal data class ComponentDocumentReturn(
    val id: String,
    val module: String,
    val taskID: String,
    val workspaceID: String,
    val path: String,
    val versionCode: Long,
    val createdAt: Long,
    val process: String,
    val installSession: Int? = null,
)

internal object ComponentDocumentReturnPolicy {
    const val MAX_AGE = 24 * 60 * 60 * 1000L

    fun valid(value: ComponentDocumentReturn): Boolean =
        listOf(value.id, value.taskID, value.workspaceID, value.process).all { raw ->
            runCatching { UUID.fromString(raw).toString().equals(raw, true) }.getOrDefault(false)
        } && value.module in setOf("cadpreview", "officepreview") &&
            value.versionCode > 0 && value.createdAt > 0 &&
            (value.installSession == null || value.installSession >= 0) &&
            value.path.length in 1..4096 && !value.path.startsWith('/') &&
            value.path.none { it == '\\' || it.code < 32 || it.code == 127 } &&
            value.path.split('/').none { it.isEmpty() || it == "." || it == ".." } &&
            value.path.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT) in
                if (value.module == "officepreview") setOf("docx", "xlsx", "pptx")
                else setOf("floecad", "dwg", "dxf", "step", "stp", "iges", "igs", "brep",
                    "glb", "gltf", "obj", "stl", "3mf")

    fun mayRestore(value: ComponentDocumentReturn, now: Long, version: Long,
                   process: String, installed: Boolean): Boolean =
        valid(value) && value.installSession != null && value.versionCode == version &&
            !value.process.equals(process, true) && installed && now >= value.createdAt &&
            now - value.createdAt <= MAX_AGE

    fun owns(value: ComponentDocumentReturn, task: String, workspace: String): Boolean =
        value.taskID.equals(task, true) && value.workspaceID.equals(workspace, true)
}
