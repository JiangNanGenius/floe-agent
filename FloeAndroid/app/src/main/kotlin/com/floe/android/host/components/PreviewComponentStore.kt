// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.components

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal data class PreviewComponentState(val installing: Boolean = false, val installed: Boolean = false,
    val downloadedBytes: Long = 0, val totalBytes: Long = 0, val installedBytes: Long = 0,
    val inUse: Boolean = false, val failure: String? = null)

/** Immutable Git source + APK-pinned per-file hashes, never a mutable remote manifest.
 * Only viewer assets are downloaded; no executable host/Android code is loaded here. */
internal class PreviewComponentStore private constructor(context: Context) {
    private val context = context.applicationContext
    private val root = File(this.context.filesDir, "PreviewComponents")
    private val serial = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var installingJob: Job? = null
    @Volatile private var downloading: HttpURLConnection? = null
    private val gate = Any()
    private val leases = HashSet<String>()
    private val manifestText = this.context.assets.open("preview_components/cad.json").bufferedReader().use { it.readText() }
    private val manifest = JSONObject(manifestText)
    private val rows = manifest.getJSONArray("files")
    private val id = manifest.getString("id").also { require(it == "cad-v1") }
    private val directory = File(root, id)
    private val manifestHash = digest(manifestText.toByteArray())
    private val mutable = MutableStateFlow(PreviewComponentState(totalBytes = (0 until rows.length()).sumOf { rows.getJSONObject(it).getLong("bytes") }))
    val state = mutable.asStateFlow()

    fun cancelInstall() { installingJob?.cancel(); downloading?.disconnect() }

    fun requestInstallCad() {
        if (state.value.installing) return
        scope.launch { runCatching { installCad() } }
    }
    fun requestUninstallCad() { scope.launch {
        runCatching { uninstallCad() }.onSuccess { removed ->
            if (!removed) mutable.value = state.value.copy(failure = "component_in_use")
        }.onFailure { mutable.value = state.value.copy(failure = "component_remove_failed") }
    } }

    suspend fun acquireCad(owner: String, current: () -> Boolean) = withContext(Dispatchers.IO) { serial.withLock {
        ensureInstalled()
        currentCoroutineContext().ensureActive()
        check(current())
        synchronized(gate) { leases += owner }
        refresh()
    } }
    fun releaseCad(owner: String) { synchronized(gate) { leases -= owner }; refresh() }
    suspend fun installCad() = withContext(Dispatchers.IO) { serial.withLock { ensureInstalled() } }

    fun cadFile(name: String): File? {
        if (!name.matches(Regex("[A-Za-z0-9_.-]+"))) return null
        val target = File(directory, name)
        if (Files.isSymbolicLink(directory.toPath()) || Files.isSymbolicLink(target.toPath())) return null
        return target.takeIf { ready() && it.isFile && it.canonicalFile.parentFile == directory.canonicalFile }
    }

    private fun ready(): Boolean = runCatching {
        !Files.isSymbolicLink(directory.toPath()) && File(directory, ".ready").readText() == manifestHash
    }.getOrDefault(false)

    private suspend fun ensureInstalled() {
        if (ready()) { refresh(); return }
        root.mkdirs()
        check(!Files.isSymbolicLink(root.toPath()))
        // Serial ownership proves these previous-process partial downloads are unused.
        root.listFiles().orEmpty().filter { it.name.startsWith("$id.install-") &&
            !Files.isSymbolicLink(it.toPath()) }.forEach { it.deleteRecursively() }
        val stage = File(root, "$id.install-${UUID.randomUUID()}")
        check(stage.mkdir())
        installingJob = currentCoroutineContext()[Job]
        mutable.value = state.value.copy(installing = true, failure = null, downloadedBytes = 0)
        try {
            for (index in 0 until rows.length()) {
                currentCoroutineContext().ensureActive()
                val entry = rows.getJSONObject(index)
                val name = entry.getString("name")
                require(name.matches(Regex("[A-Za-z0-9_.-]+")))
                val expectedBytes = entry.getLong("bytes")
                require(expectedBytes in 0..64L * 1_024 * 1_024)
                val source = manifest.getString("sourceCommit")
                require(source.matches(Regex("[a-f0-9]{40}")))
                val connection = URL("https://raw.githubusercontent.com/JiangNanGenius/floe-agent/$source/${manifest.getString("sourceRoot")}/$name")
                    .openConnection() as HttpURLConnection
                downloading = connection
                try {
                    connection.connectTimeout = 20_000; connection.readTimeout = 20_000
                    connection.instanceFollowRedirects = false
                    check(connection.responseCode == 200)
                    val hash = MessageDigest.getInstance("SHA-256")
                    var bytes = 0L
                    connection.inputStream.use { input -> File(stage, name).outputStream().use { output ->
                        val buffer = ByteArray(65_536)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            bytes += count; check(bytes <= expectedBytes)
                            hash.update(buffer, 0, count); output.write(buffer, 0, count)
                            mutable.value = state.value.copy(downloadedBytes = state.value.downloadedBytes + count)
                        }
                        output.fd.sync()
                    } }
                    check(bytes == expectedBytes && hex(hash.digest()) == entry.getString("sha256"))
                } finally { connection.disconnect(); downloading = null }
            }
            File(stage, ".ready").outputStream().use { it.write(manifestHash.toByteArray()); it.fd.sync() }
            check(synchronized(gate) { leases.isEmpty() })
            if (directory.exists()) check(directory.deleteRecursively())
            Files.move(stage.toPath(), directory.toPath(), StandardCopyOption.ATOMIC_MOVE)
            mutable.value = state.value.copy(installing = false)
            refresh()
        } catch (error: Exception) {
            stage.deleteRecursively()
            mutable.value = state.value.copy(installing = false, failure = "component_install_failed")
            throw error
        } finally { installingJob = null }
    }

    suspend fun uninstallCad(): Boolean = withContext(Dispatchers.IO) { serial.withLock {
        if (synchronized(gate) { leases.isNotEmpty() }) return@withLock false
        check(!Files.isSymbolicLink(root.toPath()) && !Files.isSymbolicLink(directory.toPath()))
        val result = !directory.exists() || directory.deleteRecursively()
        refresh(); result
    } }
    fun refresh() {
        val present = ready()
        mutable.value = state.value.copy(installed = present,
            installedBytes = if (present) state.value.totalBytes else 0,
            inUse = synchronized(gate) { leases.isNotEmpty() })
    }
    companion object {
        @Volatile private var shared: PreviewComponentStore? = null
        fun get(context: Context): PreviewComponentStore = shared ?: synchronized(this) {
            shared ?: PreviewComponentStore(context).also { shared = it }
        }
        private fun hex(value: ByteArray) = value.joinToString("") { "%02x".format(it) }
        private fun digest(value: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(value))
    }
}
