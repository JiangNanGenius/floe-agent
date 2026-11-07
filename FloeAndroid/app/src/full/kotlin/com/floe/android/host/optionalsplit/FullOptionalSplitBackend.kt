// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.optionalsplit

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.floe.android.BuildConfig
import com.floe.android.host.update.AndroidRelease
import com.floe.android.host.update.AndroidReleaseFeed
import com.floe.android.host.update.GitHubAndroidReleaseFeed
import com.floe.android.host.update.HttpsDownloadTransport
import com.floe.android.host.update.SharedPrefsUpdateStore
import com.floe.android.host.update.Sha256Sums
import com.floe.android.host.update.UpdateConfig
import com.google.android.play.core.splitcompat.SplitCompat
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import java.net.HttpURLConnection
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Same-package feature installation for ONE declared optional split, exactly
 * as the Office preview already does it: the release asset named by the spec
 * is downloaded from the repository release that matches this exact app
 * version, its SHA-256 is verified against the release's own SHA256SUMS, and
 * the system PackageInstaller validates split name, base version and signer
 * atomically. Read-back determines completion; an unsigned or version-mismatched
 * offer fails closed here and can never be announced installed. Parameterized
 * by [OptionalComponentSpec] so Office and CAD share one framework. */
internal class FullOptionalSplitBackend(
    private val context: Context,
    private val spec: OptionalComponentSpec,
    private val scope: CoroutineScope,
    private val publish: (OptionalComponentState) -> Unit,
    private val refresh: () -> Unit,
    private val canRemove: () -> Boolean,
) : OptionalComponentBackend {
    private val prefs = context.getSharedPreferences(spec.prefsName, Context.MODE_PRIVATE)
    private val documentReturns = (context.applicationContext as? com.floe.android.FloeApplication)
        ?.componentDocumentReturns
    private val root = File(context.filesDir, spec.stagingDir)
    private val gate = Any()
    @Volatile private var job: Job? = null
    @Volatile private var cancellationJob: Job? = null
    private var terminalWait: Job? = null
    @Volatile private var downloading: HttpURLConnection? = null
    private var activity = WeakReference<Activity>(null)
    private var pending: Intent? = null

    init {
        if (prefs.contains("session")) emit(OptionalComponentState(
            if (prefs.getBoolean("remove", false)) "removing" else "installing"))
    }

    override fun install() {
        launchOwned {
            try {
                emit(OptionalComponentState("downloading"))
                withContext(Dispatchers.Main) {
                    ContextCompat.startForegroundService(
                        context, Intent(context, requireNotNull(spec.downloadService)))
                }
                val target = download()
                currentCoroutineContext().ensureActive()
                prefs.edit().putString("staged", target.name).commit()
                if (!context.packageManager.canRequestPackageInstalls()) {
                    pending = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        android.net.Uri.parse("package:${context.packageName}"))
                    emit(OptionalComponentState("permission", pendingIntent = pending))
                    return@launchOwned
                }
                installStaged(target)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                emit(OptionalComponentState("failed", failure = "component_install_failed"))
            } finally {
                context.stopService(Intent(context, spec.downloadService))
            }
        }
    }

    private suspend fun download(): File {
        val owner = checkNotNull(currentCoroutineContext()[Job])
        val connected: (HttpURLConnection) -> Unit = { bindConnection(owner, it) }
        val feed = GitHubAndroidReleaseFeed(UpdateConfig.REPOSITORY_OWNER,
            UpdateConfig.REPOSITORY_NAME, onConnection = connected)
        var page: Int? = 1
        var release: AndroidRelease? = null
        while (page != null) {
            currentCoroutineContext().ensureActive()
            val result = feed.fetchPage(page)
            currentCoroutineContext().ensureActive()
            release = AndroidReleaseFeed.parsePage(result.body)
                .firstOrNull { it.version.toString() == BuildConfig.VERSION_NAME }
            if (release != null) break
            page = result.nextPage
        }
        val entry = checkNotNull(release)
        val name = spec.assetName()
        val asset = checkNotNull(entry.assets[name])
        require(asset.sizeBytes in 1..600L * 1_024 * 1_024)
        val transport = HttpsDownloadTransport(onConnection = connected)
        val checksums = transport.open(entry.checksums.downloadUrl, null, null)
        check(checksums.code == 200)
        val text = checksums.stream.use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8_192)
            while (true) {
                val count = input.read(buffer)
                    currentCoroutineContext().ensureActive()
                if (count < 0) break
                check(output.size() + count <= AndroidReleaseFeed.MAX_CHECKSUMS_BYTES)
                output.write(buffer, 0, count)
            }
            output.toString("UTF-8")
        }
        val expected = checkNotNull(Sha256Sums.parse(text)[name])
        root.mkdirs()
        val target = File(root, "${spec.module}-${BuildConfig.VERSION_CODE}.apk")
        if (target.isFile && target.length() == asset.sizeBytes && hash(target, owner) == expected) return target
        val part = File(root, "${spec.module}-${BuildConfig.VERSION_CODE}.part")
        try {
            val response = transport.open(asset.downloadUrl, null, null)
            check(response.code == 200)
            val digest = MessageDigest.getInstance("SHA-256")
            var bytes = 0L
            response.stream.use { input -> part.outputStream().use { output ->
                val buffer = ByteArray(65_536)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    currentCoroutineContext().ensureActive()
                    if (count < 0) break
                    bytes += count; check(bytes <= asset.sizeBytes)
                    digest.update(buffer, 0, count); output.write(buffer, 0, count)
                    emit(OptionalComponentState("downloading", bytes, asset.sizeBytes))
                }
                output.fd.sync()
            } }
            check(bytes == asset.sizeBytes && hex(digest.digest()) == expected)
            currentCoroutineContext().ensureActive()
            java.nio.file.Files.move(part.toPath(), target.toPath(),
                java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            return target
        } finally {
            part.delete()
        }
    }

    private suspend fun installStaged(file: File) {
        check(context.packageManager.getPackageInfo(context.packageName, 0)
            .longVersionCode == BuildConfig.VERSION_CODE.toLong())
        // The self-updater and optional split cannot commit overlapping installs.
        check(SharedPrefsUpdateStore(context).pendingInstallJson == null)
        commit(remove = false, file = file)
    }

    override fun uninstall() {
        if (!canRemove()) return
        launchOwned {
            try {
                commit(remove = true, file = null)
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                emit(OptionalComponentState("failed", failure = "component_remove_failed"))
            }
        }
    }

    private suspend fun commit(remove: Boolean, file: File?) {
        val operation = currentCoroutineContext()
        synchronized(PackageInstallAdmission.lock) {
            operation.ensureActive()
            PackageInstallAdmission.requireComponentSlot(context)
            check(context.packageManager.getPackageInfo(context.packageName, 0)
                .longVersionCode == BuildConfig.VERSION_CODE.toLong())
            if (remove) check(canRemove()) { "component_in_use" }
            commitAdmitted(remove, file, operation)
        }
    }

    private fun commitAdmitted(remove: Boolean, file: File?, operation: CoroutineContext) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_INHERIT_EXISTING).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= 34) setDontKillApp(true)
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
            if (file != null) setSize(file.length())
        }
        val id = installer.createSession(params)
        val token = UUID.randomUUID().toString()
        var handedOff = false
        try {
            installer.openSession(id).use { session ->
                if (remove) session.removeSplit(spec.module)
                else {
                    checkNotNull(file)
                    session.openWrite("${spec.module}.apk", 0, file.length()).use { output ->
                        file.inputStream().use { it.copyTo(output, 65_536) }
                        session.fsync(output)
                    }
                }
                operation.ensureActive()
                check(prefs.edit().putInt("session", id).putString("token", token)
                    .putBoolean("remove", remove)
                    .putLong("version", BuildConfig.VERSION_CODE.toLong()).commit())
                val intent = Intent(context, requireNotNull(spec.resultReceiver))
                    .setAction(spec.resultAction)
                    .putExtra("token", token)
                    .putExtra("module", spec.module)
                    .putExtra("session", id)
                val result = PendingIntent.getBroadcast(context, id, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                emit(OptionalComponentState(if (remove) "removing" else "installing"))
                operation.ensureActive()
                if (!remove) documentReturns?.arm(spec.module, id)
                session.commit(result.intentSender)
                handedOff = true
            }
        } finally {
            if (!handedOff) {
                documentReturns?.disarm(spec.module, id)
                runCatching { installer.abandonSession(id) }
                prefs.edit().remove("session").remove("token").apply()
            }
        }
    }

    override fun onInstallResult(intent: Intent) = synchronized(PackageInstallAdmission.lock) {
        handleInstallResult(intent)
    }

    private fun handleInstallResult(intent: Intent) {
        if (cancellationJob?.isActive == true) return
        if (intent.getIntExtra("session", -1) != prefs.getInt("session", -2) ||
            intent.getStringExtra("token") != prefs.getString("token", null)
        ) {
            return
        }
        terminalWait?.cancel()
        terminalWait = null
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        android.util.Log.i("FloeOptionalSplit", "result module=${spec.module} status=$status")
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            pending = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            emit(OptionalComponentState("confirm", pendingIntent = pending))
            return
        }
        val remove = prefs.getBoolean("remove", false)
        val versionMatches = context.packageManager.getPackageInfo(context.packageName, 0)
            .longVersionCode == prefs.getLong("version", -1)
        prefs.edit().remove("session").remove("token").remove("remove").remove("staged").commit()
        pending = null
        val present = spec.installed(context)
        if (status == PackageInstaller.STATUS_SUCCESS && versionMatches && present != remove) {
            if (present) SplitCompat.install(context)
            if (present) documentReturns?.completedInProcess(spec.module)
            emit(OptionalComponentState(if (present) "installed" else "missing"))
            if (present) {
                root.listFiles().orEmpty()
                    .filter { it.extension in setOf("apk", "part") }
                    .forEach { it.delete() }
            }
            refresh()
        } else if (status == PackageInstaller.STATUS_FAILURE_ABORTED) {
            documentReturns?.disarm(spec.module, intent.getIntExtra("session", -1))
            emit(OptionalComponentState("cancelled"))
        } else {
            documentReturns?.disarm(spec.module, intent.getIntExtra("session", -1))
            emit(OptionalComponentState("failed", failure = "component_install_unconfirmed"))
        }
    }

    override fun onForeground(activity: Activity) {
        this.activity = WeakReference(activity)
        if (job?.isActive == true || cancellationJob?.isActive == true) return
        if (prefs.contains("session")) {
            val ownedSession = prefs.getInt("session", -1)
            val session = context.packageManager.packageInstaller
                .getSessionInfo(ownedSession)
            if (session == null) {
                val remove = prefs.getBoolean("remove", false)
                val versionMatches = context.packageManager.getPackageInfo(context.packageName, 0)
                    .longVersionCode == prefs.getLong("version", -1)
                val present = spec.installed(context)
                if (versionMatches && present != remove) {
                    prefs.edit().remove("session").remove("token").remove("staged").remove("remove").commit()
                    if (present) SplitCompat.install(context)
                    if (present) documentReturns?.completedInProcess(spec.module)
                    emit(OptionalComponentState(if (present) "installed" else "missing"))
                    refresh()
                } else awaitTerminalResult(ownedSession)
            }
        } else if (prefs.contains("staged") &&
            context.packageManager.canRequestPackageInstalls() &&
            !spec.installed(context)
        ) {
            val name = prefs.getString("staged", null)
            if (name == "${spec.module}-${BuildConfig.VERSION_CODE}.apk") {
                val file = File(root, name)
                if (file.isFile) launchOwned {
                    try {
                        installStaged(file)
                    } catch (_: Exception) {
                        emit(OptionalComponentState("failed", failure = "component_install_failed"))
                    }
                }
            }
            prefs.edit().remove("staged").apply()
        }
    }

    /** The confirmation Activity can return before the terminal broadcast.
     * Session disappearance is not a failure receipt: keep its exact token
     * briefly so a genuine ABORTED result can still settle cancellation. */
    private fun awaitTerminalResult(ownedSession: Int) {
        if (terminalWait?.isActive == true) return
        pending = null
        emit(OptionalComponentState("installing"))
        terminalWait = scope.launch(Dispatchers.IO) {
            delay(2_000)
            synchronized(PackageInstallAdmission.lock) {
                if (prefs.getInt("session", -1) != ownedSession ||
                    context.packageManager.packageInstaller.getSessionInfo(ownedSession) != null) return@synchronized
                val remove = prefs.getBoolean("remove", false)
                val versionMatches = context.packageManager.getPackageInfo(context.packageName, 0)
                    .longVersionCode == prefs.getLong("version", -1)
                val present = spec.installed(context)
                prefs.edit().remove("session").remove("token").remove("staged").remove("remove").commit()
                if (versionMatches && present != remove) {
                    if (present) {
                        SplitCompat.install(context)
                        documentReturns?.completedInProcess(spec.module)
                    }
                    emit(OptionalComponentState(if (present) "installed" else "missing"))
                    refresh()
                } else {
                    documentReturns?.disarm(spec.module, ownedSession)
                    emit(OptionalComponentState("failed", failure = "component_install_unconfirmed"))
                }
            }
        }
    }

    override fun confirm(activity: Activity) {
        val intent = pending
        if (intent != null) {
            runCatching { activity.startActivity(intent) }
                .onFailure {
                    emit(OptionalComponentState("failed", failure = "component_confirmation_failed"))
                }
        } else {
            onForeground(activity)
        }
    }

    override fun cancel() {
        synchronized(gate) {
            if (cancellationJob?.isActive == true) return
            val previous = job
            terminalWait?.cancel()
            terminalWait = null
            val connection = downloading
            previous?.cancel()
            publish(OptionalComponentState("cancelling", cachedBytes = cacheBytes()))
            cancellationJob = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                runCatching { connection?.disconnect() }
                previous?.join()
                synchronized(PackageInstallAdmission.lock) {
                    val id = prefs.getInt("session", -1)
                    documentReturns?.disarm(spec.module, id)
                    if (id >= 0) runCatching {
                        context.packageManager.packageInstaller.abandonSession(id)
                    }
                    prefs.edit().remove("session").remove("token").remove("staged")
                        .remove("remove").commit()
                    pending = null
                }
                publish(OptionalComponentState(
                    if (spec.installed(context)) "installed" else "missing",
                    cachedBytes = cacheBytes()))
                refresh()
            }
            cancellationJob?.start()
        }
    }

    override fun cacheBytes(): Long = stagedFiles().filter {
        java.nio.file.Files.isRegularFile(it.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
    }.sumOf { it.length() }

    override fun clearCache() {
        launchOwned {
            try {
                emit(OptionalComponentState("clearing"))
                for (file in stagedFiles()) {
                    currentCoroutineContext().ensureActive()
                    java.nio.file.Files.delete(file.toPath())
                }
                prefs.edit().remove("staged").commit()
                emit(OptionalComponentState(if (spec.installed(context)) "installed" else "missing"))
                refresh()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                emit(OptionalComponentState("failed", failure = "component_cache_clear_failed"))
            }
        }
    }

    private fun stagedFiles(): List<File> {
        if (java.nio.file.Files.isSymbolicLink(root.toPath())) return emptyList()
        val pattern = Regex("${spec.module}-[0-9]+\\.(apk|part)")
        return root.listFiles().orEmpty().filter { file ->
            pattern.matches(file.name) && !java.nio.file.Files.isDirectory(
                file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)
        }
    }

    private fun launchOwned(block: suspend CoroutineScope.() -> Unit) {
        synchronized(gate) {
            if (job?.isActive == true || cancellationJob?.isActive == true || prefs.contains("session")) return
            job = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                try { block() }
                finally { synchronized(gate) { downloading = null } }
            }
            job?.start()
        }
    }

    private fun bindConnection(owner: Job, connection: HttpURLConnection) {
        val admitted = synchronized(gate) {
            if (job !== owner || !owner.isActive) false
            else { downloading = connection; true }
        }
        if (!admitted) {
            connection.disconnect()
            throw CancellationException("component_download_cancelled")
        }
    }

    private fun emit(value: OptionalComponentState) {
        synchronized(gate) {
            if (cancellationJob?.isActive == true) return
            publish(if (value.phase == "downloading") value else value.copy(cachedBytes = cacheBytes()))
        }
    }

    private fun hash(file: File, owner: Job): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65_536)
            while (true) {
                owner.ensureActive()
                val n = input.read(buffer)
                if (n < 0) break
                hash.update(buffer, 0, n)
            }
        }
        return hex(hash.digest())
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
}

/** Generic dispatcher so each component keeps one tiny manifest-declared
 * receiver that forwards the session result to its own controller. */
internal object OptionalSplitInstallResults {
    fun dispatch(
        spec: OptionalComponentSpec,
        handler: (Intent) -> Unit,
        intent: Intent,
    ) {
        if (intent.action != spec.resultAction) return
        if (intent.getStringExtra("module") != spec.module) return
        handler(intent)
    }
}
