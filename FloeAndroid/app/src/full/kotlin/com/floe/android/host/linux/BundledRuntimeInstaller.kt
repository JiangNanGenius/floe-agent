// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.floe.android.runtimeipc.RuntimePackages
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** GitHub-only OS package installation; credentials never cross into the component. */
class BundledRuntimeInstaller(private val context: Context) {
    private val pair = RuntimePackages.forCore(context.packageName)

    sealed interface Action {
        data class GrantInstallPermission(val intent: Intent) : Action
        data class AwaitingSystem(val sessionID: Int) : Action
    }

    /** Invoke off-main after an explicit user action. This never bypasses Android consent. */
    fun install(): Action {
        if (!context.packageManager.canRequestPackageInstalls()) {
            return Action.GrantInstallPermission(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}")))
        }
        val packages = context.packageManager
        // Explicit user retry may replace only this Core app's unfinished
        // installation of its exact runtime component. Installed data stays.
        for (pending in packages.packageInstaller.mySessions.filter { it.appPackageName == pair.runtime }) {
            packages.packageInstaller.abandonSession(pending.sessionId)
        }
        val staging = File(context.cacheDir, "linux-component-install").apply { mkdirs() }
        check(staging.canonicalFile.parentFile == context.cacheDir.canonicalFile && staging.isDirectory)
        val apk = File(staging, "runtime.apk")
        try {
            val expected = context.assets.open("linux-runtime/runtime.apk.sha256").bufferedReader().use { it.readText() }.trim()
            require(expected.matches(Regex("[0-9a-f]{64}")))
            val digest = MessageDigest.getInstance("SHA-256")
            context.assets.open("linux-runtime/runtime.apk").use { input ->
                java.io.FileOutputStream(apk).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var bytes = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        bytes += count
                        check(bytes <= 512L * 1024 * 1024) { "Bundled runtime package exceeds its budget" }
                        digest.update(buffer, 0, count); output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            check(digest.digest().joinToString("") { "%02x".format(it) } == expected)
            @Suppress("DEPRECATION")
            val archive = checkNotNull(packages.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNING_CERTIFICATES))
            @Suppress("DEPRECATION")
            val own = packages.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            check(archive.packageName == pair.runtime && archive.longVersionCode == own.longVersionCode)
            fun certificates(info: android.content.pm.PackageInfo): Set<String> =
                checkNotNull(info.signingInfo).apkContentsSigners.map { signature ->
                    MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
                }.toSet().also { check(it.isNotEmpty()) }
            check(certificates(archive) == certificates(own)) { "Runtime signing identity differs" }
            val parameters = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                .apply {
                    setAppPackageName(pair.runtime); setSize(apk.length())
                    if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                }
            val installer = packages.packageInstaller
            val sessionID = installer.createSession(parameters)
            try {
                installer.openSession(sessionID).use { session ->
                    session.openWrite("runtime.apk", 0, apk.length()).use { output ->
                        apk.inputStream().use { it.copyTo(output) }; session.fsync(output)
                    }
                    // PackageInstaller fills the explicit, private callback's
                    // status extras. The PendingIntent is never exposed to a model.
                    val callback = PendingIntent.getBroadcast(context, sessionID,
                        Intent(context, RuntimeInstallReceiver::class.java).putExtra("floeSessionID", sessionID),
                        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    session.commit(callback.intentSender)
                }
            } catch (failure: Exception) {
                installer.abandonSession(sessionID)
                throw failure
            }
            return Action.AwaitingSystem(sessionID)
        } finally {
            // PackageInstaller owns its fsynced copy after commit; no duplicate APK cache.
            apk.delete(); staging.delete()
        }
    }
}

/** Process-local UI handoff only; PackageInstaller owns durable session state. */
object RuntimeInstallState {
    sealed interface Result {
        data object Idle : Result
        data class Confirmation(val sessionID: Int, val intent: Intent) : Result
        data class Finished(val sessionID: Int, val success: Boolean) : Result
    }
    internal val mutable = MutableStateFlow<Result>(Result.Idle)
    val state = mutable.asStateFlow()
}

class RuntimeInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sessionID = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (sessionID < 0 || sessionID != intent.getIntExtra("floeSessionID", -2)) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                if (confirmation != null) RuntimeInstallState.mutable.value =
                    RuntimeInstallState.Result.Confirmation(sessionID, confirmation)
                // The visible UI presents the system confirmation. A broadcast
                // never launches an Activity from the background.
            }
            PackageInstaller.STATUS_SUCCESS -> RuntimeInstallState.mutable.value = RuntimeInstallState.Result.Finished(sessionID, true)
            else -> RuntimeInstallState.mutable.value = RuntimeInstallState.Result.Finished(sessionID, false)
        }
    }
}
