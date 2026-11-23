// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.CommitPermit
import com.floe.android.safgateway.RecoveryReceipt
import com.floe.android.safgateway.SafCommitCoordinator
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafUriRef
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Crash-safe edit-session metadata + the App-owned commit coordinator.
 *
 * DURABILITY CONTRACT (mirrors the workspace Office lane, Main steering
 * 2026-10-24, adapted for this App-only page): before ANY destructive
 * provider write the recovery receipt is persisted here and only then is the
 * write permitted. The gateway keeps its RAM pointer; after process death
 * this journal is the reconciliation authority for session state and the
 * receipt registry. Recovery bytes always stay on disk — adoption removes
 * the pointer, never the file.
 */
internal class SpaceFilesEditJournal(
    val root: File,
    /** Resolves the session working file from its persisted name. */
    private val workingFileFor: (sessionId: String, fileName: String) -> File,
) : SafCommitCoordinator {

    private val receiptsDir = File(root, "receipts")

    init {
        check(!Files.isSymbolicLink(root.toPath()))
        check(root.isDirectory || root.mkdirs())
        check(!Files.isSymbolicLink(receiptsDir.toPath()))
        check(receiptsDir.isDirectory || receiptsDir.mkdirs())
    }

    // ------------------------------------------------------------------
    // Session rows
    // ------------------------------------------------------------------

    fun load(): List<SpaceFilesEditSession> {
        val files = root.listFiles { f -> f.name.endsWith(".json") } ?: error("journalUnavailable")
        check(files.size <= MAX_RECORDS) { "journalCapacity" }
        return files.map { file ->
            check(!Files.isSymbolicLink(file.toPath()) && file.isFile && file.length() in 1..MAX_JSON_BYTES)
            val value = Json.parseToJsonElement(file.readText()) as? JsonObject ?: error("journalMalformed")
            decode(value).also { check(file.name == "${it.id}.json") }
        }.map { decoded ->
            // Resolve the persisted file name against the owner-created
            // working directory (never trust a stored absolute path).
            decoded.copy(workingFile = workingFileFor(decoded.id, decoded.workingFile.name))
        }
    }

    fun save(session: SpaceFilesEditSession) {
        val destination = File(root, "${session.id}.json")
        check(!Files.isSymbolicLink(destination.toPath()))
        if (!destination.exists()) {
            check((root.listFiles { f -> f.name.endsWith(".json") }?.size
                ?: error("journalUnavailable")) < MAX_RECORDS) { "journalCapacity" }
        }
        val part = File(root, ".${UUID.randomUUID()}.part")
        try {
            val bytes = encode(session).toString().toByteArray(Charsets.UTF_8)
            check(bytes.size <= MAX_JSON_BYTES)
            FileOutputStream(part).use { it.write(bytes); it.fd.sync() }
            Files.move(part.toPath(), destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            part.delete()
        }
    }

    fun remove(sessionId: String) {
        // The working copy + recovery bytes are never deleted here; only the
        // metadata row goes away once the session is truly finished.
        File(root, "$sessionId.json").delete()
    }

    // ------------------------------------------------------------------
    // SafCommitCoordinator: persist the receipt, then permit the write.
    // ------------------------------------------------------------------

    override fun requestCommitPermit(receipt: RecoveryReceipt): CommitPermit {
        val destination = File(receiptsDir, "${receipt.receiptId}.json")
        if (destination.exists()) return CommitPermit.Permitted
        val part = File(receiptsDir, ".${UUID.randomUUID()}.part")
        return try {
            val bytes = encodeReceipt(receipt).toString().toByteArray(Charsets.UTF_8)
            check(bytes.size <= MAX_JSON_BYTES)
            FileOutputStream(part).use { it.write(bytes); it.fd.sync() }
            Files.move(part.toPath(), destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            CommitPermit.Permitted
        } catch (error: Exception) {
            part.delete()
            CommitPermit.Refused("journal:${error.javaClass.simpleName}")
        }
    }

    /** Reconciliation hook after a restart: receipts still registered in the
     * journal but unknown to the gateway RAM registry. */
    fun persistedReceiptIds(): Set<String> =
        receiptsDir.listFiles { f -> f.name.endsWith(".json") }?.map { it.name.removeSuffix(".json") }
            ?.toSet().orEmpty()

    companion object {
        private const val MAX_RECORDS = 256
        private const val MAX_JSON_BYTES = 64L * 1024

        internal fun encode(session: SpaceFilesEditSession): JsonObject = buildJsonObject {
            put("version", 1)
            put("id", session.id)
            put("targetUri", session.target.uri.uriString)
            session.target.documentId?.let { put("targetDocumentId", it) }
            session.target.parentDocumentId?.let { put("targetParentDocumentId", it) }
            session.target.tree?.let { put("targetTree", it.uriString) }
            put("name", session.name)
            put("mimeType", session.mimeType)
            put("baselineSha256", session.baselineSha256)
            put("baselineBytes", session.baselineBytes)
            put("workingFileName", session.workingFile.name)
            put("createdAt", session.createdAtMillis)
            put("updatedAt", session.updatedAtMillis)
            put("phase", session.phase.name)
            session.errorCode?.let { put("errorCode", it) }
            session.savedSiblingName?.let { put("savedSiblingName", it) }
            session.recoveryReceiptId?.let { put("recoveryReceiptId", it) }
        }

        /** Single versioned decoder; unknown fields are ignored, corrupt rows fail closed. */
        internal fun decode(value: JsonObject): SpaceFilesEditSession {
            fun text(key: String): String? = (value[key] as? JsonPrimitive)
                ?.takeIf { it.isString }?.contentOrNull
            fun long(key: String): Long? = (value[key] as? JsonPrimitive)?.longOrNull
            val id = text("id") ?: error("journalMalformed")
            val targetUri = text("targetUri") ?: error("journalMalformed")
            val tree = text("targetTree")?.let { SafUriRef(it) }
            val target = SafDocumentRef(
                tree = tree,
                documentId = text("targetDocumentId"),
                parentDocumentId = text("targetParentDocumentId"),
                uri = SafUriRef(targetUri),
            )
            val name = text("name") ?: error("journalMalformed")
            val mimeType = text("mimeType") ?: error("journalMalformed")
            val baselineSha = text("baselineSha256") ?: error("journalMalformed")
            val baselineBytes = long("baselineBytes") ?: error("journalMalformed")
            val workingFileName = text("workingFileName") ?: error("journalMalformed")
            val phase = text("phase")?.let { raw ->
                SpaceFilesEditPhase.entries.firstOrNull { it.name == raw }
            } ?: error("journalMalformed")
            return SpaceFilesEditSession(
                id = id,
                target = target,
                name = name,
                mimeType = mimeType,
                baselineSha256 = baselineSha,
                baselineBytes = baselineBytes,
                // Placeholder resolved by the owner against the edits root at load.
                workingFile = File(workingFileName),
                createdAtMillis = long("createdAt") ?: 0L,
                updatedAtMillis = long("updatedAt") ?: 0L,
                phase = phase,
                errorCode = text("errorCode"),
                savedSiblingName = text("savedSiblingName"),
                recoveryReceiptId = text("recoveryReceiptId"),
            )
        }

        internal fun encodeReceipt(receipt: RecoveryReceipt): JsonObject = buildJsonObject {
            put("receiptId", receipt.receiptId)
            put("fileName", receipt.file.name)
            put("sha256", receipt.sha256)
            put("bytes", receipt.bytes)
            put("targetUri", receipt.targetUri.uriString)
            receipt.targetDocumentId?.let { put("targetDocumentId", it) }
            put("issuedAt", receipt.issuedAtMillis)
        }
    }
}
