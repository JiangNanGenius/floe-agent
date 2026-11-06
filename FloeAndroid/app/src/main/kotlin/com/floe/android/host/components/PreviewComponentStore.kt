// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.components

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal data class PreviewComponentState(val installing: Boolean = false, val installed: Boolean = false,
    val downloadedBytes: Long = 0, val totalBytes: Long = 0, val installedBytes: Long = 0,
    val inUse: Boolean = false, val failure: String? = null, val cancelling: Boolean = false)

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
    private val commit = ComponentDirectoryCommit(root, id)
    private val directory = commit.directory
    private val manifestHash = digest(manifestText.toByteArray())
    private val mutable = MutableStateFlow(PreviewComponentState(totalBytes = (0 until rows.length()).sumOf { rows.getJSONObject(it).getLong("bytes") }))
    val state = mutable.asStateFlow()

    fun cancelInstall() {
        val connection = synchronized(gate) {
            val job = installingJob ?: return
            if (!state.value.installing || state.value.cancelling) return
            mutable.update { it.copy(cancelling = true) }
            job.cancel()
            downloading
        }
        // Closing a network response may block. Keep it off the UI thread,
        // and capture this attempt's connection, never a later download.
        scope.launch { runCatching { connection?.disconnect() } }
    }

    fun requestInstallCad() {
        if (state.value.installing) return
        scope.launch { runCatching { installCad() } }
    }
    fun requestUninstallCad() { scope.launch {
        runCatching { uninstallCad() }.onSuccess { removed ->
            mutable.update { it.copy(failure = if (removed) null else "component_in_use") }
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
        ComponentDirectoryCommit.hasCompletionMarker(directory) && File(directory, ".ready").readText() == manifestHash &&
            (0 until rows.length()).all { index ->
                val entry = rows.getJSONObject(index)
                val file = File(directory, entry.getString("name"))
                Files.isRegularFile(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS) && file.length() == entry.getLong("bytes")
            }
    }.getOrDefault(false)

    private suspend fun ensureInstalled() {
        if (synchronized(gate) { leases.isNotEmpty() }) {
            if (ready()) { refresh(); return }
            mutable.update { it.copy(failure = "component_in_use") }
            error("component_in_use")
        }
        var stage: File? = null
        val installJob = checkNotNull(currentCoroutineContext()[Job])
        synchronized(gate) { installingJob = installJob }
        try {
            commit.recover()
            commit.discardStaleStages()
            if (ready()) { mutable.update { it.copy(failure = null) }; refresh(); return }
            check(!Files.isSymbolicLink(root.toPath()))
            check(root.isDirectory || root.mkdirs())
            val destination = File(root, "$id.install-${UUID.randomUUID()}")
            check(destination.mkdir())
            stage = destination
            synchronized(gate) {
                installJob.ensureActive()
                mutable.update { it.copy(installing = true, cancelling = false, failure = null, downloadedBytes = 0) }
            }
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
                synchronized(gate) {
                    installJob.ensureActive()
                    downloading = connection
                }
                try {
                    connection.connectTimeout = 20_000; connection.readTimeout = 20_000
                    connection.instanceFollowRedirects = false
                    check(connection.responseCode == 200)
                    val hash = MessageDigest.getInstance("SHA-256")
                    var bytes = 0L
                    connection.inputStream.use { input -> File(destination, name).outputStream().use { output ->
                        val buffer = ByteArray(65_536)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            bytes += count; check(bytes <= expectedBytes)
                            hash.update(buffer, 0, count); output.write(buffer, 0, count)
                            mutable.update { it.copy(downloadedBytes = it.downloadedBytes + count) }
                        }
                        output.fd.sync()
                    } }
                    check(bytes == expectedBytes && hex(hash.digest()) == entry.getString("sha256"))
                } finally {
                    connection.disconnect()
                    synchronized(gate) { if (downloading === connection) downloading = null }
                }
            }
            File(destination, ".ready").outputStream().use { it.write(manifestHash.toByteArray()); it.fd.sync() }
            currentCoroutineContext().ensureActive()
            check(synchronized(gate) { leases.isEmpty() })
            commit.promote(destination)
        } catch (error: Exception) {
            val cancelled = error is CancellationException || !currentCoroutineContext().isActive
            mutable.update { it.copy(failure = when {
                error is ComponentDirectoryCommit.RestorePending -> "component_restore_pending"
                error is ComponentDirectoryCommit.CleanupPending -> "component_cleanup_pending"
                cancelled -> null
                else -> "component_install_failed"
            }) }
            if (error is ComponentDirectoryCommit.CleanupPending && ready()) return
            throw error
        } finally {
            stage?.let { pending ->
                runCatching { commit.discardStage(pending) }.onFailure {
                    mutable.update { it.copy(failure = if (it.failure == "component_restore_pending")
                        it.failure else "component_cleanup_pending") }
                }
            }
            synchronized(gate) {
                if (installingJob === installJob) {
                    installingJob = null
                    mutable.update { it.copy(installing = false, cancelling = false) }
                }
            }
            refresh()
        }
    }

    suspend fun uninstallCad(): Boolean = withContext(Dispatchers.IO) { serial.withLock {
        if (synchronized(gate) { leases.isNotEmpty() }) return@withLock false
        try { commit.uninstall(); true } finally { refresh() }
    } }
    fun refresh() {
        val present = ready()
        val bytes = commit.storedBytes()
        val inUse = synchronized(gate) { leases.isNotEmpty() }
        mutable.update { it.copy(installed = present, installedBytes = bytes, inUse = inUse) }
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
