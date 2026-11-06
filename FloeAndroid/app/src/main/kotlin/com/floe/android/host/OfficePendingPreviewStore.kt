// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/** One unowned READ_ONLY provider preview waiting for an optional component.
 * No provider URI, task binding, credential or write authority is restored. */
internal class OfficePendingPreviewStore(private val snapshots: File, private val directory: File) {
    data class Snapshot(val path: String, val sha256: String, val bytes: Long, val displayName: String)
    private val record get() = File(directory, "pending.json")

    @Synchronized fun save(snapshot: Snapshot) {
        verify(snapshot)
        check(!Files.isSymbolicLink(directory.toPath()))
        check(directory.isDirectory || directory.mkdirs())
        check(!Files.isSymbolicLink(record.toPath()))
        val part = File(directory, "${UUID.randomUUID()}.part")
        try {
            val json = JSONObject().put("schema", 1).put("path", snapshot.path)
                .put("sha256", snapshot.sha256).put("bytes", snapshot.bytes)
                .put("displayName", snapshot.displayName).toString().toByteArray(Charsets.UTF_8)
            check(json.size <= 32 * 1024)
            FileOutputStream(part).use { it.write(json); it.fd.sync() }
            Files.move(part.toPath(), record.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { part.delete() }
    }

    /** Off-main: a saved path is never evidence that its bytes are unchanged. */
    @Synchronized fun load(): Snapshot? = read()?.also(::verify)

    @Synchronized fun clearMatching(path: String, sha256: String, bytes: Long) {
        val saved = read() ?: return
        if (saved.path == path && saved.sha256 == sha256 && saved.bytes == bytes) {
            check(record.delete() || !record.exists())
        }
    }

    private fun read(): Snapshot? {
        check(!Files.isSymbolicLink(directory.toPath()) && !Files.isSymbolicLink(record.toPath()))
        if (!record.exists()) return null
        check(record.isFile && record.length() in 1..32 * 1024)
        val json = JSONObject(record.readText(Charsets.UTF_8))
        check(json.getInt("schema") == 1)
        return Snapshot(json.getString("path"), json.getString("sha256"), json.getLong("bytes"), json.getString("displayName"))
    }

    private fun verify(snapshot: Snapshot) {
        check(snapshot.sha256.matches(Regex("[0-9a-f]{64}")) && snapshot.bytes in 1..WorkspaceOfficeSnapshotStager.MAX_BYTES)
        check(snapshot.displayName.isNotBlank() && snapshot.displayName.length <= 240 &&
            snapshot.displayName.none { it.code < 32 || it.code == 127 || it == '/' || it == '\\' })
        val file = File(snapshot.path)
        val parent = checkNotNull(file.parentFile)
        check(!Files.isSymbolicLink(snapshots.toPath()) && !Files.isSymbolicLink(parent.toPath()) && !Files.isSymbolicLink(file.toPath()))
        check(parent.canonicalFile.parentFile == snapshots.canonicalFile && UUID.fromString(parent.name).toString() == parent.name)
        check(file.canonicalPath == snapshot.path && file.extension.lowercase() in setOf("docx", "xlsx", "pptx"))
        check(file.isFile && file.length() == snapshot.bytes)
        val hash = MessageDigest.getInstance("SHA-256")
        var count = 0L
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                count += n; check(count <= snapshot.bytes); hash.update(buffer, 0, n)
            }
        }
        check(count == snapshot.bytes && hash.digest().joinToString("") { "%02x".format(it) } == snapshot.sha256)
    }
}
