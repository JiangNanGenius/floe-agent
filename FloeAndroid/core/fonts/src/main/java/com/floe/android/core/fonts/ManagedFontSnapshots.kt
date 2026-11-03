// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.fonts

import android.graphics.Typeface
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Resource adapter for the existing C07 backup/rollback journal. The App is
 * still the sole catalogue mutator. Only App-derived roots and canonical UUIDs
 * enter this API, never archive/model paths. Validation precedes live adoption. */
class ManagedFontSnapshots(private val store: ManagedFontStore) {
    private fun id(value: String): String = value.also { require(UUID.fromString(it).toString() == it) }
    private fun directory(kind: String, value: String, create: Boolean, exclusive: Boolean = false): File {
        val parent = File(store.filesRoot, kind)
        if (create) store.ensureDirectory(parent)
        require(OsConstants.S_ISDIR(Os.lstat(parent.path).st_mode))
        val result = File(parent, id(value))
        if (exclusive) check(result.mkdir()) { "Snapshot already exists" }
        else if (create) store.ensureDirectory(result)
        require(OsConstants.S_ISDIR(Os.lstat(result.path).st_mode))
        return result
    }
    private fun read(file: File, max: Int = 262144): ByteArray {
        file.takeIf { it.exists() }?.let { store.regular(it); require(it.length() <= max) }
        File(file.path + ".bak").takeIf { it.exists() }?.let { store.regular(it); require(it.length() <= max) }
        return AtomicFile(file).openRead().use { input ->
            val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
            while (true) { val n = input.read(buffer); if (n < 0) break
                require(out.size() + n <= max); out.write(buffer, 0, n) }
            out.toByteArray()
        }
    }
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it) }
    private fun atomic(file: File, bytes: ByteArray) {
        file.takeIf { it.exists() }?.let(store::regular)
        val value = AtomicFile(file); val out = value.startWrite()
        try { out.write(bytes); value.finishWrite(out) }
        catch (e: Throwable) { value.failWrite(out); throw e }
        try { store.syncDirectory(file.parentFile!!) } catch (e: Exception) { throw FontCommitUncertain(e) }
    }
    fun export(snapshotID: String): JSONObject = store.locked {
        val entries = store.read(); val catalog = store.rawCatalog()
        val dir = directory("FontBackupSnapshotsV1", snapshotID, true, exclusive = true)
        require(dir.list()?.isEmpty() == true) { "Snapshot already exists" }
        try {
            entries.forEach { entry -> Os.link(store.verifiedPayload(entry).path, File(dir, "${entry.id}.ttf").path) }
            atomic(File(dir, "catalog.json"), catalog)
            JSONObject().put("ok", true).put("snapshotID", snapshotID).put("count", entries.size)
                .put("catalogSHA256", hash(catalog))
        } catch (e: Throwable) {
            dir.listFiles()?.forEach { it.delete() }; dir.delete(); throw e
        }
    }
    /** Native C07 copies exactly the archive's managed-font records into the
     * fixed incoming UUID directory with its descriptor-safe copy gate. */
    fun prepare(restoreID: String, expectedCatalogSHA: String, mayCommit: () -> Boolean): JSONObject = store.locked {
        val input = directory("FontRestoreIncomingV1", restoreID, false)
        val catalog = read(File(input, "catalog.json"))
        require(hash(catalog) == expectedCatalogSHA) { "Font snapshot changed" }
        val records = store.parseCatalog(catalog)
        require(records.sumOf { it.bytes } <= 128L * 1024 * 1024)
        require(input.list()?.toSet() == records.map { "${it.id}.ttf" }.toSet() + "catalog.json") { "Unexpected font snapshot files" }
        val target = directory("FontRestoreTransactionsV1", restoreID, true)
        val stateFile = File(target, "transaction.json")
        if (stateFile.exists() || File(stateFile.path + ".bak").exists()) {
            val previous = JSONObject(String(read(stateFile, 1048576), Charsets.UTF_8))
            require(previous.getString("sourceSHA256") == expectedCatalogSHA) { "Restore identity reused" }
            return@locked JSONObject().put("ok", true).put("count", records.size)
        }
        require(target.list()?.isEmpty() == true)
        try {
            val admitted = records.map { record ->
                check(mayCommit()) { "Font restore cancelled" }
                val source = File(input, "${record.id}.ttf"); store.regular(source)
                require(source.length() == record.bytes && store.digest(source) == record.id)
                val copy = File(target, "${record.id}.ttf")
                Os.link(source.path, copy.path)
                val names = SfntMetadata.metadata(copy)
                names.indices.forEach { face -> require(Typeface.Builder(copy).setTtcIndex(face).setFallback(null).build() != null) }
                require(store.digest(copy) == record.id)
                ManagedFontStore.Entry(record.id, record.bytes, names.mapIndexed { index, name ->
                    ManagedFontStore.Face(index, name.displayName, name.aliases)
                })
            }
            val existing = store.read()
            val merged = existing + admitted.filter { entry -> existing.none { it.id == entry.id } }
            require(merged.size <= 256 && merged.sumOf { it.bytes } <= 128L * 1024 * 1024) { "Font library is full" }
            check(mayCommit())
            atomic(File(target, "admitted.json"), store.document(admitted, 0))
            atomic(stateFile, JSONObject().put("schema", 1).put("sourceSHA256", expectedCatalogSHA)
                .put("phase", "prepared").put("count", records.size).toString().toByteArray())
            JSONObject().put("ok", true).put("count", records.size)
        } catch (e: Throwable) {
            // This directory has not adopted anything into the live catalogue.
            target.listFiles()?.forEach { it.delete() }; target.delete(); throw e
        }
    }
    fun status(restoreID: String): JSONObject = store.locked {
        val dir = directory("FontRestoreTransactionsV1", restoreID, false)
        val state = JSONObject(String(read(File(dir, "transaction.json"), 1048576), Charsets.UTF_8))
        require(state.getString("phase") in setOf("prepared", "committed"))
        JSONObject().put("ok", true).put("count", state.getInt("count"))
            .put("sourceSHA256", state.getString("sourceSHA256"))
    }
    fun adopt(restoreID: String, mayCommit: () -> Boolean): JSONObject = store.locked {
        val dir = directory("FontRestoreTransactionsV1", restoreID, false)
        val stateFile = File(dir, "transaction.json")
        val state = JSONObject(String(read(stateFile, 1048576), Charsets.UTF_8))
        val phase = state.getString("phase")
        require(phase != "rolledBack") { "Restore already rolled back" }
        if (phase == "committed") return@locked JSONObject().put("ok", true).put("count", state.getInt("count"))
        val current = store.rawCatalog(); val currentHash = hash(current)
        // Reconstruct only the exact known commit after a lost acknowledgement.
        if (state.has("afterSHA256")) {
            if (currentHash == state.getString("afterSHA256")) {
                state.put("phase", "committed"); atomic(stateFile, state.toString().toByteArray())
                return@locked JSONObject().put("ok", true).put("count", state.getInt("count"))
            }
            require(currentHash == state.getString("beforeSHA256")) { "Font restore outcome is unknown" }
        }
        val admitted = store.parseCatalog(read(File(dir, "admitted.json")))
        val existing = store.read()
        admitted.filter { entry -> existing.any { it.id == entry.id } }.forEach(store::verifiedPayload)
        val added = admitted.filter { entry -> existing.none { it.id == entry.id } }
        val merged = existing + added
        require(merged.size <= 256 && merged.sumOf { it.bytes } <= 128L * 1024 * 1024)
        val payloads = store.root.listFiles()?.filter { it.name.matches(Regex("[a-f0-9]{64}\\.ttf")) }
            ?: error("Font recovery storage unavailable")
        payloads.forEach(store::regular)
        val missing = added.filterNot { File(store.root, "${it.id}.ttf").exists() }
        require(payloads.size + missing.size <= 512 && payloads.sumOf { it.length() } + missing.sumOf { it.bytes } <= 256L * 1024 * 1024)
        added.forEach { entry ->
            check(mayCommit())
            val source = File(dir, "${entry.id}.ttf"); store.regular(source)
            require(source.length() == entry.bytes && store.digest(source) == entry.id)
            val destination = File(store.root, "${entry.id}.ttf")
            if (!destination.exists()) Os.link(source.path, destination.path)
            store.verifiedPayload(entry)
        }
        val revision = JSONObject(String(current, Charsets.UTF_8)).optLong("revision", 0)
        require(revision >= 0 && revision < Long.MAX_VALUE)
        val after = store.document(merged, revision + 1)
        atomic(File(dir, "before.json"), current)
        state.put("beforeSHA256", currentHash).put("afterSHA256", hash(after))
        atomic(stateFile, state.toString().toByteArray()) // durable intent before catalogue publication
        check(mayCommit())
        store.commit(merged)
        require(hash(store.rawCatalog()) == hash(after)) { "Font catalogue read-back failed" }
        state.put("phase", "committed"); atomic(stateFile, state.toString().toByteArray())
        JSONObject().put("ok", true).put("count", state.getInt("count"))
    }
    /** Called only after the native C07 journal has a durable complete record.
     * Keep the tiny idempotency receipt; retire duplicate working/recovery links. */
    fun complete(restoreID: String): JSONObject = store.locked {
        val dir = directory("FontRestoreTransactionsV1", restoreID, false)
        val state = JSONObject(String(read(File(dir, "transaction.json"), 1048576), Charsets.UTF_8))
        require(state.getString("phase") == "committed") { "Font restore is not complete" }
        dir.listFiles()?.filter { file ->
            file.name in setOf("before.json", "admitted.json", "before.json.bak", "admitted.json.bak") ||
                file.name.matches(Regex("[a-f0-9]{64}\\.ttf"))
        }?.forEach { file -> store.regular(file); check(file.delete()) }
        store.syncDirectory(dir)
        JSONObject().put("ok", true)
    }
    fun rollback(restoreID: String, allowMissing: Boolean = false): JSONObject = store.locked {
        val parent = File(store.filesRoot, "FontRestoreTransactionsV1")
        if (!File(parent, id(restoreID)).exists()) {
            check(allowMissing) { "Font restore state is missing" }
            return@locked JSONObject().put("ok", true)
        }
        val dir = directory("FontRestoreTransactionsV1", restoreID, false)
        val stateFile = File(dir, "transaction.json")
        val state = JSONObject(String(read(stateFile, 1048576), Charsets.UTF_8))
        if (state.getString("phase") == "rolledBack") return@locked JSONObject().put("ok", true)
        if (state.has("afterSHA256")) {
            val currentBytes = store.rawCatalog()
            val current = hash(currentBytes)
            if (state.has("rollbackSHA256") && current == state.getString("rollbackSHA256")) {
                state.put("phase", "rolledBack"); atomic(stateFile, state.toString().toByteArray())
                return@locked JSONObject().put("ok", true)
            }
            if (current == state.getString("afterSHA256")) {
                val before = read(File(dir, "before.json"))
                require(hash(before) == state.getString("beforeSHA256"))
                val entries = store.parseCatalog(before)
                val revision = JSONObject(String(currentBytes, Charsets.UTF_8)).optLong("revision", 0)
                require(revision >= 0 && revision < Long.MAX_VALUE)
                state.put("rollbackSHA256", hash(store.document(entries, revision + 1)))
                atomic(stateFile, state.toString().toByteArray())
                store.restoreCatalog(entries)
                require(hash(store.rawCatalog()) == state.getString("rollbackSHA256"))
            } else require(current == state.getString("beforeSHA256")) { "Font rollback conflicts with a newer library change" }
        }
        state.put("phase", "rolledBack"); atomic(stateFile, state.toString().toByteArray())
        JSONObject().put("ok", true)
    }
}
