// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.floe.android.BuildConfig
import com.floe.android.FloeApplication
import com.floe.android.host.update.*
import com.google.android.play.core.splitcompat.SplitCompat
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*

internal object OfficeComponentDistribution {
    fun installed(context: Context): Boolean = runCatching {
        OfficeComponentController.MODULE in context.packageManager.getPackageInfo(context.packageName, 0).splitNames.orEmpty()
    }.getOrDefault(false)
    fun create(context: Context, scope: CoroutineScope, publish: (OfficeComponentState) -> Unit,
        refresh: () -> Unit, canRemove: () -> Boolean): OfficeComponentBackend =
        FullOfficeComponentBackend(context, scope, publish, refresh, canRemove)
}

/** Same-package feature installation. The system validates split name, base
 * version/dependencies and signer atomically; read-back determines completion. */
private class FullOfficeComponentBackend(private val context: Context, private val scope: CoroutineScope,
    private val publish: (OfficeComponentState) -> Unit, private val refresh: () -> Unit,
    private val canRemove: () -> Boolean) : OfficeComponentBackend {
    private val prefs = context.getSharedPreferences("office_component_install", Context.MODE_PRIVATE)
    private val root = File(context.filesDir, "OfficeComponent")
    private var job: Job? = null
    private var activity = WeakReference<Activity>(null)
    private var pending: Intent? = null
    init {
        if (prefs.contains("session")) publish(OfficeComponentState(
            if (prefs.getBoolean("remove", false)) "removing" else "installing"))
    }

    override fun install() {
        if (job?.isActive == true || prefs.contains("session")) return
        job = scope.launch(Dispatchers.IO) {
            try {
                publish(OfficeComponentState("downloading"))
                withContext(Dispatchers.Main) {
                    ContextCompat.startForegroundService(context, Intent(context, OfficeComponentDownloadService::class.java))
                }
                val target = download()
                currentCoroutineContext().ensureActive()
                prefs.edit().putString("staged", target.name).commit()
                if (!context.packageManager.canRequestPackageInstalls()) {
                    pending = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        android.net.Uri.parse("package:${context.packageName}"))
                    publish(OfficeComponentState("permission", pendingIntent = pending))
                    return@launch
                }
                installStaged(target)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { publish(OfficeComponentState("failed", failure = "component_install_failed")) }
            finally { context.stopService(Intent(context, OfficeComponentDownloadService::class.java)) }
        }
    }

    private suspend fun download(): File {
        val feed = GitHubAndroidReleaseFeed(UpdateConfig.REPOSITORY_OWNER, UpdateConfig.REPOSITORY_NAME)
        var page: Int? = 1
        var release: AndroidRelease? = null
        while (page != null) {
            currentCoroutineContext().ensureActive()
            val result = feed.fetchPage(page)
            release = AndroidReleaseFeed.parsePage(result.body).firstOrNull { it.version.toString() == BuildConfig.VERSION_NAME }
            if (release != null) break
            page = result.nextPage
        }
        val entry = checkNotNull(release)
        val name = OfficeComponentController.assetName()
        val asset = checkNotNull(entry.assets[name])
        require(asset.sizeBytes in 1..600L * 1_024 * 1_024)
        val transport = HttpsDownloadTransport()
        val checksums = transport.open(entry.checksums.downloadUrl, null, null)
        check(checksums.code == 200)
        val text = checksums.stream.use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8_192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                check(output.size() + count <= AndroidReleaseFeed.MAX_CHECKSUMS_BYTES)
                output.write(buffer, 0, count)
            }
            output.toString("UTF-8")
        }
        val expected = checkNotNull(Sha256Sums.parse(text)[name])
        root.mkdirs()
        val target = File(root, "office-${BuildConfig.VERSION_CODE}.apk")
        if (target.isFile && target.length() == asset.sizeBytes && hash(target) == expected) return target
        val part = File(root, "office-${BuildConfig.VERSION_CODE}.part")
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
                    if (count < 0) break
                    bytes += count; check(bytes <= asset.sizeBytes)
                    digest.update(buffer, 0, count); output.write(buffer, 0, count)
                    publish(OfficeComponentState("downloading", bytes, asset.sizeBytes))
                }
                output.fd.sync()
            } }
            check(bytes == asset.sizeBytes && hex(digest.digest()) == expected)
            java.nio.file.Files.move(part.toPath(), target.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            return target
        } finally { part.delete() }
    }

    private fun installStaged(file: File) {
        check(context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode == BuildConfig.VERSION_CODE.toLong())
        // The self-updater and optional split cannot commit overlapping installs.
        check(SharedPrefsUpdateStore(context).pendingInstallJson == null)
        commit(remove = false, file = file)
    }

    override fun uninstall() {
        if (job?.isActive == true || prefs.contains("session") || !canRemove()) return
        job = scope.launch(Dispatchers.IO) {
            try { commit(remove = true, file = null) }
            catch (_: Exception) { publish(OfficeComponentState("failed", failure = "component_remove_failed")) }
        }
    }

    private fun commit(remove: Boolean, file: File?) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_INHERIT_EXISTING).apply {
            setAppPackageName(context.packageName)
            if (Build.VERSION.SDK_INT >= 34) setDontKillApp(true)
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            if (file != null) setSize(file.length())
        }
        val id = installer.createSession(params)
        val token = UUID.randomUUID().toString()
        var handedOff = false
        try {
            installer.openSession(id).use { session ->
                if (remove) session.removeSplit(OfficeComponentController.MODULE)
                else {
                    checkNotNull(file)
                    session.openWrite("officepreview.apk", 0, file.length()).use { output ->
                        file.inputStream().use { it.copyTo(output, 65_536) }; session.fsync(output)
                    }
                }
                check(prefs.edit().putInt("session", id).putString("token", token)
                    .putBoolean("remove", remove).putLong("version", BuildConfig.VERSION_CODE.toLong()).commit())
                val intent = Intent(context, OfficeComponentInstallReceiver::class.java)
                    .setAction("com.floe.office.COMPONENT_INSTALL_RESULT").putExtra("token", token).putExtra("session", id)
                val result = PendingIntent.getBroadcast(context, id, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                publish(OfficeComponentState(if (remove) "removing" else "installing"))
                session.commit(result.intentSender)
                handedOff = true
            }
        } finally {
            if (!handedOff) {
                runCatching { installer.abandonSession(id) }
                prefs.edit().remove("session").remove("token").apply()
            }
        }
    }

    override fun onInstallResult(intent: Intent) {
        if (intent.getIntExtra("session", -1) != prefs.getInt("session", -2) ||
            intent.getStringExtra("token") != prefs.getString("token", null)) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            pending = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
            publish(OfficeComponentState("confirm", pendingIntent = pending))
            return
        }
        val remove = prefs.getBoolean("remove", false)
        val versionMatches = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode == prefs.getLong("version", -1)
        prefs.edit().remove("session").remove("token").remove("remove").commit()
        pending = null
        val present = OfficeComponentController.installed(context)
        if (status == PackageInstaller.STATUS_SUCCESS && versionMatches && present != remove) {
            if (present) SplitCompat.install(context)
            publish(OfficeComponentState(if (present) "installed" else "missing"))
            refresh()
            if (present) root.listFiles().orEmpty().filter { it.extension in setOf("apk", "part") }.forEach { it.delete() }
        } else publish(OfficeComponentState("failed", failure = "component_install_unconfirmed"))
    }

    override fun onForeground(activity: Activity) {
        this.activity = WeakReference(activity)
        if (prefs.contains("session")) {
            val session = context.packageManager.packageInstaller.getSessionInfo(prefs.getInt("session", -1))
            if (session == null) {
                prefs.edit().remove("session").remove("token").commit()
                if (OfficeComponentController.installed(context)) refresh()
                else publish(OfficeComponentState("failed", failure = "component_install_unconfirmed"))
            }
        } else if (prefs.contains("staged") && context.packageManager.canRequestPackageInstalls() &&
            !OfficeComponentController.installed(context)) {
            val name = prefs.getString("staged", null)
            if (name == "office-${BuildConfig.VERSION_CODE}.apk") {
                val file = File(root, name)
                if (file.isFile) job = scope.launch(Dispatchers.IO) {
                    try { installStaged(file) }
                    catch (_: Exception) { publish(OfficeComponentState("failed", failure = "component_install_failed")) }
                }
            }
            prefs.edit().remove("staged").apply()
        }
    }
    override fun confirm(activity: Activity) {
        val intent = pending
        if (intent != null) runCatching { activity.startActivity(intent) }
            .onFailure { publish(OfficeComponentState("failed", failure = "component_confirmation_failed")) }
        else onForeground(activity)
    }
    override fun cancel() {
        job?.cancel()
        val id = prefs.getInt("session", -1)
        if (id >= 0) runCatching { context.packageManager.packageInstaller.abandonSession(id) }
        prefs.edit().remove("session").remove("token").remove("staged").commit()
        pending = null
        publish(OfficeComponentState(if (OfficeComponentController.installed(context)) "installed" else "missing"))
    }
    private fun hash(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(65_536)
            while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) } }
        return hex(hash.digest())
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
}

class OfficeComponentInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        (context.applicationContext as? FloeApplication)?.officeComponent?.onInstallResult(intent)
    }
}
