// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Crash-safe handoff metadata only. Original file truth remains in workspace CAS. */
internal class ExternalEditJournal(val root: File) {
    init {
        check(!Files.isSymbolicLink(root.toPath()))
        check(root.isDirectory || root.mkdirs())
    }

    fun load(): List<ExternalEditRecord> {
        val files = root.listFiles { f -> f.name.endsWith(".json") }
            ?: error("journalUnavailable")
        check(files.size <= MAX_RECORDS) { "journalCapacity" }
        return files.map { file ->
            check(!Files.isSymbolicLink(file.toPath()) && file.isFile && file.length() in 1..MAX_JSON_BYTES)
            val objectValue = Json.parseToJsonElement(file.readText()) as? JsonObject
                ?: error("journalMalformed")
            decode(objectValue).also { check(file.name == "${it.id}.json") }
        }
    }

    fun save(record: ExternalEditRecord) {
        val destination = File(root, "${record.id}.json")
        check(!Files.isSymbolicLink(destination.toPath()))
        if (!destination.exists()) check((root.listFiles { f -> f.name.endsWith(".json") }?.size
            ?: error("journalUnavailable")) < MAX_RECORDS) { "journalCapacity" }
        val part = File(root, ".${UUID.randomUUID()}.part")
        try {
            val bytes = encode(record).toString().toByteArray(Charsets.UTF_8)
            check(bytes.size <= MAX_JSON_BYTES)
            FileOutputStream(part).use { it.write(bytes); it.fd.sync() }
            Files.move(part.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING)
        } finally { part.delete() }
    }

    companion object {
        private const val MAX_RECORDS = 256
        private const val MAX_JSON_BYTES = 64L * 1024

        internal fun encode(row: ExternalEditRecord): JsonObject = buildJsonObject {
            put("version", 1); put("id", row.id)
            put("taskID", row.owner.taskID); put("workspaceID", row.owner.workspaceID)
            put("logicalPath", row.logicalPath); put("displayName", row.displayName)
            put("baselineSHA256", row.baselineSHA256); put("baselineBytes", row.baselineBytes)
            row.sourceID?.let { put("sourceID", it) }
            row.sourceRevision?.let { put("sourceRevision", it) }
            put("phase", row.phase.name)
            row.pendingSHA256?.let { put("pendingSHA256", it) }
            row.pendingBytes?.let { put("pendingBytes", it) }
            row.conflictSHA256?.let { put("conflictSHA256", it) }
            row.editedSHA256?.let { put("editedSHA256", it) }
            row.errorCode?.let { put("errorCode", it) }
            put("updatedAt", row.updatedAt)
            put("initialSHA256", row.initialSHA256)
        }

        /** Single versioned decoder; unknown/corrupt entries are retained, never erased. */
        internal fun decode(value: JsonObject): ExternalEditRecord {
            fun text(key: String): String? = (value[key] as? JsonPrimitive)
                ?.takeIf { it.isString }?.contentOrNull
            fun number(key: String): Long? = (value[key] as? JsonPrimitive)
                ?.takeIf { !it.isString }?.longOrNull
            require(number("version") == 1L)
            return ExternalEditRecord(
                id = requireNotNull(text("id")),
                owner = ExternalEditOwner(requireNotNull(text("taskID")), requireNotNull(text("workspaceID"))),
                logicalPath = requireNotNull(text("logicalPath")),
                displayName = requireNotNull(text("displayName")),
                baselineSHA256 = requireNotNull(text("baselineSHA256")),
                baselineBytes = requireNotNull(number("baselineBytes")),
                sourceID = text("sourceID"), sourceRevision = text("sourceRevision"),
                phase = ExternalEditPhase.valueOf(requireNotNull(text("phase"))),
                pendingSHA256 = text("pendingSHA256"), pendingBytes = number("pendingBytes"),
                conflictSHA256 = text("conflictSHA256"), editedSHA256 = text("editedSHA256"),
                errorCode = text("errorCode"), updatedAt = requireNotNull(number("updatedAt")),
                initialSHA256 = text("initialSHA256") ?: requireNotNull(text("baselineSHA256")),
            )
        }
    }
}
