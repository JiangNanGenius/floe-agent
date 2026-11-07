// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import android.content.Context
import com.floe.android.BuildConfig
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

/** One pending first-use document, stored outside backup. A record is armed
 * only by the real channel installer. A normal launch, staged download or old
 * cancelled selection is never sufficient to restore it. */
internal class ComponentDocumentReturns(
    private val directory: File,
    private val versionCode: Long,
    private val process: String = UUID.randomUUID().toString(),
    private val now: () -> Long = System::currentTimeMillis,
) {
    constructor(context: Context) : this(context.noBackupFilesDir, BuildConfig.VERSION_CODE.toLong())
    private val file = File(directory, "component-document-return.json")
    private var saved = read()
    private val mutableRestoring = MutableStateFlow<ComponentDocumentReturn?>(null)
    val restoring = mutableRestoring.asStateFlow()

    @Synchronized fun prepare(module: String, task: String, workspace: String, path: String): ComponentDocumentReturn {
        val value = ComponentDocumentReturn(UUID.randomUUID().toString(), module, task,
            workspace, path, versionCode, now(), process)
        require(ComponentDocumentReturnPolicy.valid(value))
        persist(value)
        return value
    }

    /** Called before the real system install can kill this process. Does not
     * grant anything to a settings-only install or a record from a dead process. */
    @Synchronized fun arm(module: String, session: Int) {
        val value = saved?.takeIf { it.module == module && it.process == process } ?: return
        persist(value.copy(installSession = session))
    }

    @Synchronized fun disarm(module: String, session: Int? = null) {
        saved?.takeIf { it.module == module && (session == null || it.installSession == session) }
            ?.let { persist(it.copy(installSession = null)) }
    }

    @Synchronized fun completedInProcess(module: String) {
        if (saved?.let { it.module == module && it.process == process } == true) clear()
    }

    @Synchronized fun candidate(installed: (String) -> Boolean): ComponentDocumentReturn? =
        saved?.takeIf { ComponentDocumentReturnPolicy.mayRestore(it,
            now(), versionCode, process, installed(it.module)) }

    @Synchronized fun isCurrent(id: String): Boolean = saved?.id == id

    @Synchronized fun discard(id: String) {
        if (saved?.id == id) clear()
    }

    @Synchronized fun beginRestore(value: ComponentDocumentReturn): Boolean {
        if (saved != value) return false
        mutableRestoring.value = value
        return true
    }

    /** Explicit navigation fences pending work; composition disposal never calls this. */
    @Synchronized fun clear(exceptID: String? = null) {
        if (exceptID != null && saved?.id == exceptID) return
        check(file.delete() || !file.exists()) { "component_return_clear_failed" }
        saved = null
        mutableRestoring.value = null
    }

    @Synchronized fun consume(value: ComponentDocumentReturn, task: String, workspace: String): Boolean {
        if (mutableRestoring.value != value || saved != value ||
            !ComponentDocumentReturnPolicy.owns(value, task, workspace)) return false
        clear()
        return true
    }

    private fun persist(value: ComponentDocumentReturn) {
        val json = JSONObject().put("schema", 1).put("id", value.id).put("module", value.module)
            .put("task", value.taskID).put("workspace", value.workspaceID).put("path", value.path)
            .put("version", value.versionCode).put("created", value.createdAt).put("process", value.process)
        value.installSession?.let { json.put("session", it) }
        check(!Files.isSymbolicLink(directory.toPath()) && !Files.isSymbolicLink(file.toPath()))
        check(directory.isDirectory || directory.mkdirs())
        val part = File(directory, "component-return-${UUID.randomUUID()}.part")
        try {
            FileOutputStream(part).use {
                it.write(json.toString().toByteArray(Charsets.UTF_8))
                it.fd.sync()
            }
            Files.move(part.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            saved = value
        } finally { part.delete() }
    }

    private fun read(): ComponentDocumentReturn? = runCatching {
        check(!Files.isSymbolicLink(directory.toPath()) && !Files.isSymbolicLink(file.toPath()))
        if (!file.exists()) return@runCatching null
        require(file.isFile && file.length() in 1..32 * 1024)
        val json = JSONObject(file.readText(Charsets.UTF_8))
        require(json.getInt("schema") == 1)
        ComponentDocumentReturn(json.getString("id"), json.getString("module"), json.getString("task"),
            json.getString("workspace"), json.getString("path"), json.getLong("version"),
            json.getLong("created"), json.getString("process"),
            if (json.has("session")) json.getInt("session") else null).also {
                require(ComponentDocumentReturnPolicy.valid(it))
            }
    }.getOrNull()
}
