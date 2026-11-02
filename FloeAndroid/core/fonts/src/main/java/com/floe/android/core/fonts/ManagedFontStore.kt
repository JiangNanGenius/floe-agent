// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.fonts

import android.content.Context
import android.graphics.Typeface
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InterruptedIOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

/** App-owned library, independent of task deletion. Never writes system fonts.
 * Payloads are immutable. Removal detaches the catalogue entry; bytes retained
 * for already-open renderers and recovery are never advertised to fontconfig.
 * Every operation uses the same cross-process lock, including Office snapshots.
 */
class ManagedFontStore(context: Context) {
    data class Face(val index: Int, val name: String, val aliases: List<String> = listOf(name))
    data class Entry(val id: String, val bytes: Long, val faces: List<Face>) {
        fun reference(face: Face): String = "floe-font:$id:${face.index}"
    }
    private val root = File(context.applicationContext.filesDir, "ManagedFontsV1")
    private val catalog get() = AtomicFile(File(root, "catalog.json"))

    private fun ensureDirectory(dir: File) {
        if (!dir.exists()) check(dir.mkdir()) { "Cannot create font library" }
        require(OsConstants.S_ISDIR(Os.lstat(dir.path).st_mode)) { "Unsafe font library directory" }
    }
    private fun <T> locked(block: () -> T): T = synchronized(processLock) {
        ensureDirectory(root)
        val lock = File(root, "catalog.lock")
        if (lock.exists()) regular(lock)
        RandomAccessFile(lock, "rw").use { f -> f.channel.lock().use { block() } }
    }
    private fun regular(file: File) {
        require(OsConstants.S_ISREG(Os.lstat(file.path).st_mode)) { "Unsafe font file" }
    }
    private fun digest(file: File): String = file.inputStream().use { input ->
        val md = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(65536)
        while (true) {
            if (Thread.currentThread().isInterrupted) throw InterruptedIOException("Font operation cancelled")
            val n = input.read(buffer); if (n < 0) break
            md.update(buffer, 0, n)
        }
        md.digest().joinToString("") { "%02x".format(it) }
    }
    private fun read(): List<Entry> {
        val file = File(root, "catalog.json")
        // AtomicFile may have a previous committed backup after a crash.
        if (!file.exists() && !File(root, "catalog.json.bak").exists()) return emptyList()
        if (file.exists()) regular(file)
        File(root, "catalog.json.bak").takeIf { it.exists() }?.let(::regular)
        val data = catalog.openRead().use { it.readBytesBounded(262144) }
        val json = JSONObject(String(data, Charsets.UTF_8))
        require(json.getInt("schema") == 1) { "Unsupported font library" }
        val array = json.getJSONArray("fonts")
        require(array.length() <= 256) { "Font catalogue too large" }
        val ids = HashSet<String>()
        return List(array.length()) { i ->
            val item = array.getJSONObject(i); val id = item.getString("id")
            require(ID.matches(id) && ids.add(id)) { "Invalid font identity" }
            val bytes = item.getLong("bytes"); require(bytes in 12..SfntMetadata.MAX_BYTES)
            val faces = item.getJSONArray("faces"); require(faces.length() in 1..32)
            Entry(id, bytes, List(faces.length()) { j ->
                val face = faces.getJSONObject(j)
                require(face.getInt("index") == j)
                val name = face.getString("name").also { require(it.length in 1..160 && it.none(Char::isISOControl)) }
                val aliases = face.optJSONArray("aliases")
                require(aliases == null || aliases.length() <= 32)
                Face(j, name, if (aliases == null) listOf(name) else List(aliases.length()) { k ->
                    aliases.getString(k).also { require(it.length in 1..160 && it.none(Char::isISOControl)) }
                })
            })
        }
    }
    private fun commit(entries: List<Entry>) {
        val values = JSONArray()
        entries.forEach { entry ->
            val faces = JSONArray()
            entry.faces.forEach { faces.put(JSONObject().put("index", it.index).put("name", it.name).put("aliases", JSONArray(it.aliases))) }
            values.put(JSONObject().put("id", entry.id).put("bytes", entry.bytes).put("faces", faces))
        }
        val bytes = JSONObject().put("schema", 1).put("fonts", values).toString().toByteArray()
        require(bytes.size <= 262144) { "Font catalogue too large" }
        val output = catalog.startWrite()
        try { output.write(bytes); catalog.finishWrite(output) }
        catch (e: Throwable) { catalog.failWrite(output); throw e }
    }
    fun list(): List<Entry> = locked { read() }

    /** Caller owns the granted source stream. It is consumed and closed here. */
    fun install(input: InputStream): Entry = locked {
        val stage = File(root, "incoming-${UUID.randomUUID()}.part")
        try {
            var size = 0L
            input.use { source -> FileOutputStream(stage).use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    if (Thread.currentThread().isInterrupted) throw InterruptedIOException("Font import cancelled")
                    val n = source.read(buffer); if (n < 0) break
                    size += n; require(size <= SfntMetadata.MAX_BYTES) { "Font exceeds 32 MiB" }
                    output.write(buffer, 0, n)
                }
                output.fd.sync()
            } }
            val names = SfntMetadata.metadata(stage)
            // No fallback: a malformed face must not register as the default font.
            names.indices.forEach { index ->
                require(Typeface.Builder(stage).setTtcIndex(index).setFallback(null).build() != null) { "Android cannot load this font" }
            }
            val id = digest(stage)
            val entries = read()
            entries.firstOrNull { it.id == id }?.let { verifiedPayload(it); return@locked it }
            require(entries.size < 256 && entries.sumOf { it.bytes } + size <= 128L * 1024 * 1024) { "Font library is full" }
            val payload = File(root, "$id.ttf")
            if (payload.exists()) {
                regular(payload); require(payload.length() == size && digest(payload) == id) { "Font payload conflict" }
            } else {
                // Retained recovery payloads count toward the physical budget.
                val payloads = root.listFiles()?.filter { it.name.matches(Regex("[a-f0-9]{64}\\.ttf")) }
                    ?: error("Font library cannot be read")
                require(payloads.size < 512) { "Font recovery storage is full" }
                var retained = 0L
                payloads.forEach { regular(it); retained += it.length() }
                require(retained + size <= 256L * 1024 * 1024) { "Font recovery storage is full" }
                check(stage.renameTo(payload)) { "Cannot commit font payload" }
            }
            val entry = Entry(id, size, names.mapIndexed { index, name -> Face(index, name.displayName, name.aliases) })
            commit(entries + entry)
            require(read().any { it == entry }) { "Font catalogue read-back failed" }
            entry
        } finally { stage.delete() }
    }
    fun remove(id: String): Boolean = locked {
        require(ID.matches(id)) { "Invalid font identity" }
        val entries = read(); val remaining = entries.filterNot { it.id == id }
        if (entries.size == remaining.size) false else {
            commit(remaining)
            require(read().none { it.id == id }) { "Font removal read-back failed" }
            true
        }
    }
    private fun verifiedPayload(entry: Entry): File = File(root, "${entry.id}.ttf").also {
        regular(it)
        require(it.length() == entry.bytes && digest(it) == entry.id) { "Font payload changed" }
    }
    fun resolve(reference: String): Typeface = locked {
        val parts = reference.split(':')
        require(parts.size == 3 && parts[0] == "floe-font" && ID.matches(parts[1])) { "Invalid font reference" }
        val index = parts[2].toIntOrNull() ?: error("Invalid font face")
        val entry = read().firstOrNull { it.id == parts[1] } ?: error("This project’s font is no longer in the font library")
        require(entry.faces.any { it.index == index }) { "Font face missing" }
        Typeface.Builder(verifiedPayload(entry)).setTtcIndex(index).setFallback(null).build()
            ?: error("Android cannot load this font")
    }
    /** iOS exchanges may contain a PostScript/full/family name rather than
     * an Android digest reference. Resolve a unique imported face explicitly. */
    fun resolveImportedName(name: String): Typeface? = locked {
        val matches = read().flatMap { entry -> entry.faces.filter { face ->
            face.aliases.any { it.equals(name, ignoreCase = true) }
        }.map { entry to it } }
        require(matches.size <= 1) { "Choose a specific face for this font family" }
        val match = matches.singleOrNull() ?: return@locked null
        Typeface.Builder(verifiedPayload(match.first)).setTtcIndex(match.second.index).setFallback(null).build()
            ?: error("Android cannot load this font")
    }
    /** Immutable, active-only projection. Office reads it at engine startup;
     * changes take effect in its next engine session, never a fake hot reload. */
    fun officeSnapshot(): File = locked {
        val entries = read()
        val key = MessageDigest.getInstance("SHA-256").digest(entries.sortedBy { it.id }
            .joinToString("\n") { it.id }.toByteArray()).joinToString("") { "%02x".format(it) }
        val snapshots = File(root, "office"); ensureDirectory(snapshots)
        val target = File(snapshots, key)
        if (!target.exists()) {
            require((snapshots.list()?.size ?: error("Font snapshots unavailable")) < 1024) { "Font snapshot storage is full" }
            val stage = File(snapshots, "stage-${UUID.randomUUID()}"); ensureDirectory(stage)
            try {
                entries.forEach { entry ->
                    val source = verifiedPayload(entry)
                    val output = File(stage, "${entry.id}.ttf")
                    Os.link(source.path, output.path)
                }
                check(stage.renameTo(target)) { "Cannot commit Office fonts" }
            } finally { stage.listFiles()?.forEach { it.delete() }; stage.delete() }
        }
        require(OsConstants.S_ISDIR(Os.lstat(target.path).st_mode))
        require(target.list()?.toSet() == entries.map { "${it.id}.ttf" }.toSet()) { "Office fonts changed" }
        entries.forEach { entry -> val f = File(target, "${entry.id}.ttf"); regular(f); require(digest(f) == entry.id) }
        target
    }
    companion object {
        private val processLock = Any()
        private val ID = Regex("[a-f0-9]{64}")
        private fun InputStream.readBytesBounded(max: Int): ByteArray {
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) { val n = read(buffer); if (n < 0) break
                require(output.size() + n <= max) { "Font catalogue too large" }; output.write(buffer, 0, n) }
            return output.toByteArray()
        }
    }
}

/** Configured by the application before media export services are admitted. */
object ManagedFontTypeface {
    @Volatile private var store: ManagedFontStore? = null
    fun configure(context: Context) { store = ManagedFontStore(context) }
    fun resolve(name: String?): Typeface {
        if (name?.startsWith("floe-font:") == true) return (store ?: error("Font library unavailable")).resolve(name)
        if (name != null) store?.resolveImportedName(name)?.let { return it }
        return Typeface.create(name ?: "sans-serif", Typeface.NORMAL)
    }
}
