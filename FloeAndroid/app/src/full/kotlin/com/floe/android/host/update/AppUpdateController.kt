// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import com.floe.android.BuildConfig
import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundController
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Everything the full-flavor settings entry and update dialog render. */
internal data class AppUpdateUiState(
    val currentVersion: String,
    val autoCheckEnabled: Boolean,
    val check: AppCheckState,
    val download: AppDownloadState,
    val install: AppInstallState,
    val dialogVisible: Boolean,
    val blockingKinds: Set<OperationKind>,
    val pendingSystemIntent: Intent? = null,
    /** A persisted PackageInstaller session still owns an install attempt. */
    val pendingInstall: Boolean = false,
)

/**
 * Composition root of the GitHub full-flavor self-updater.
 *
 * Lifecycle ownership: created once per process by the Application through
 * [AppUpdateFeature.attach]; all work runs in the Application scope, so
 * rotation/navigation never owns a check, download or install. The download
 * itself is additionally hosted by [AppUpdateDownloadService] for process
 * priority, and its durable state is persisted for honest resume after
 * process death.
 */
internal class AppUpdateController private constructor(
    private val context: Context,
    private val scope: CoroutineScope,
) {
    private val store: UpdateStore = SharedPrefsUpdateStore(context)
    private val stagingDir = File(context.filesDir, UpdateConfig.STAGING_DIRECTORY)
    private val currentVersion: FloeVersion? = FloeVersion.parse(BuildConfig.VERSION_NAME)
    private val reader = ApkIdentityReader(context)
    private val checkController = UpdateCheckController(
        scope = scope,
        feed = GitHubAndroidReleaseFeed(UpdateConfig.REPOSITORY_OWNER, UpdateConfig.REPOSITORY_NAME),
        store = store,
        currentVersion = currentVersion,
        nowMillis = System::currentTimeMillis,
    )
    /**
     * Installed-base facts for the delta path. The APK itself is read from
     * `applicationInfo.sourceDir`; a split install or an unreadable base
     * simply disables deltas (the full APK path is unaffected).
     */
    private val installedBaseProvider = InstalledBaseProvider {
        val identity = reader.installed()
        val apk = reader.installedApkFile()
        if (identity == null || apk == null) {
            null
        } else {
            InstalledBaseInfo(
                apkFile = apk,
                apkSizeBytes = apk.length(),
                packageName = identity.packageName,
                versionName = identity.versionName,
                versionCode = identity.longVersionCode,
                signerSha256 = identity.signerSha256,
                hasSplitApks = reader.hasSplitApks() || !apk.isFile,
                sdkInt = android.os.Build.VERSION.SDK_INT,
            )
        }
    }
    private val downloader = UpdateDownloader(
        scope = scope,
        transport = HttpsDownloadTransport(),
        store = store,
        stagingDir = stagingDir,
        validate = { apk ->
            when (reader.rejectionFor(apk)) {
                null -> null
                else -> DownloadFailure.APK_IDENTITY
            }
        },
        deltaBaseProvider = installedBaseProvider,
    )
    private val installer = AppUpdateInstaller(
        context = context,
        scope = scope,
        store = store,
        reader = reader,
        stagingDir = stagingDir,
        heldOperationKinds = {
            runCatching { RunForegroundController.forApplication(context).heldOperationKinds() }
                .getOrDefault(emptySet())
        },
    )
    private var suppressed = false
    private var lastPhaseSignature = ""
    private var attached = false
    private val mutable = MutableStateFlow(build())
    val ui: StateFlow<AppUpdateUiState> = mutable.asStateFlow()
    val downloadState: StateFlow<AppDownloadState> = downloader.state

    fun attach() {
        if (attached) return
        attached = true
        scope.launch(Dispatchers.IO) {
            downloader.reconcile()
            installer.reconcile()
        }
        scope.launch {
            combine(
                checkController.state,
                downloader.state,
                installer.state,
            ) { check, download, install -> Triple(check, download, install) }
                .collect { refresh() }
        }
        // Startup automatic check follows the same cooldown/enabled rules as
        // every later foreground check; a failure only changes the typed
        // check state and never blocks the App.
        checkController.maybeAutoCheck()
        refresh()
    }

    fun onApplicationForeground() {
        installer.onForeground()
        checkController.maybeAutoCheck()
        refresh()
    }

    fun setAutoCheckEnabled(enabled: Boolean) {
        checkController.setAutoCheckEnabled(enabled)
        refresh()
    }

    fun checkNow() {
        checkController.manualCheck()
        refresh()
    }

    fun startDownload() {
        val available = checkController.state.value as? AppCheckState.UpdateAvailable ?: return
        startDownloadService()
        // The visible user tap is the consent for this transfer (metered or
        // not); nothing in the updater downloads without such a tap.
        downloader.start(available.release, allowDelta = true)
        refresh()
    }

    /** Explicit fallback after a delta was refused or failed. */
    fun startFullDownload() {
        val available = checkController.state.value as? AppCheckState.UpdateAvailable ?: return
        startDownloadService()
        downloader.startFull(available.release)
        refresh()
    }

    fun cancelDownload() {
        downloader.cancel()
        refresh()
    }

    fun resumeDownload() {
        startDownloadService()
        downloader.resume()
        refresh()
    }

    fun discardDownload() {
        downloader.discard()
        refresh()
    }

    fun installNow(force: Boolean) {
        val ready = downloader.state.value as? AppDownloadState.Ready ?: return
        val file = downloader.readyFile() ?: return
        installer.requestInstall(
            versionName = ready.versionName,
            apk = file,
            sha256 = ready.sha256,
            force = force,
        )
        refresh()
    }

    /**
     * Retry a failed install from the SAME verified APK. Only offered when no
     * owned pending session exists; a committed session must be resolved with
     * "cancel install" first (never a silent duplicate submit).
     */
    fun retryInstall() {
        val ready = downloader.state.value as? AppDownloadState.Ready ?: return
        if (PendingInstall.fromJson(store.pendingInstallJson) != null) return
        val file = downloader.readyFile() ?: return
        installer.retryInstall(ready.versionName, file, ready.sha256)
        refresh()
    }

    /** The unknown-sources page could not be launched on this build. */
    fun onPermissionIntentUnavailable() {
        installer.onPermissionIntentUnavailable()
        refresh()
    }

    /** The system confirmation intent could not be launched. */
    fun onConfirmationUnavailable() {
        installer.onConfirmationUnavailable()
        refresh()
    }

    fun cancelInstallWait() {
        installer.cancelWaiting()
        refresh()
    }

    fun dismissInstallFailure() {
        installer.dismissFailure()
        refresh()
    }

    /** Explicit recovery: abandon ONLY the owned pending session. */
    fun cancelPendingInstall() {
        installer.cancelPendingInstall()
        refresh()
    }

    fun clearInstallSucceeded() {
        installer.clearSucceeded()
        refresh()
    }

    /** "Later" — persists the dismissed release so it is not re-presented. */
    fun dismissDialog() {
        val available = checkController.state.value as? AppCheckState.UpdateAvailable
        // Only dismissing the new-version offer counts as "Later"; hiding a
        // progress/install surface must not mute a still-downloading update.
        val offerVisible = downloader.state.value is AppDownloadState.Idle &&
            installer.state.value is AppInstallState.Idle
        if (available != null && offerVisible) {
            checkController.markDialogDismissed(available.release)
        }
        suppressed = true
        refresh()
    }

    /** Only a visible user click may launch this intent. */
    fun consumeSystemIntent(): Intent? {
        val state = installer.state.value
        return when (state) {
            is AppInstallState.Confirming -> installer.consumeConfirmation().also { refresh() }
            is AppInstallState.NeedsPermission -> state.intent
            else -> null
        }
    }

    /** Re-open the dialog after the user minimized it (settings entry). */
    fun showDialog() {
        suppressed = false
        refresh()
    }

    fun startDownloadWork() {
        val available = checkController.state.value as? AppCheckState.UpdateAvailable
        if (available != null) downloader.start(available.release) else downloader.resume()
        refresh()
    }

    private fun startDownloadService() {
        val intent = Intent(context, AppUpdateDownloadService::class.java)
            .setAction(AppUpdateDownloadService.ACTION_START)
        // A real foreground service (dataSync type) keeps the download alive
        // across screen lock / app backgrounding instead of relying on a plain
        // started service, which Android may stop shortly after backgrounding.
        // Calls originate from a visible user action, so the background-FGS
        // start restriction does not apply; a platform refusal falls back to
        // the Application-scoped engine (the durable staging record still
        // resumes the download later).
        runCatching { context.startForegroundService(intent) }
    }

    private fun refresh() {
        val download = downloader.state.value
        val install = installer.state.value
        val signature = phaseSignature(download, install)
        if (signature != lastPhaseSignature) {
            lastPhaseSignature = signature
            // A NEW phase re-presents the dialog even if the previous one was
            // minimized; pure progress ticks do not.
            suppressed = false
        }
        mutable.value = build()
    }

    private fun phaseSignature(download: AppDownloadState, install: AppInstallState): String =
        (download::class.simpleName ?: "download") + "|" + (install::class.simpleName ?: "install")

    private fun build(): AppUpdateUiState {
        val check = checkController.state.value
        val download = downloader.state.value
        val install = installer.state.value
        val installBlocking = install is AppInstallState.WaitingForJobs
        val installVisible = install !is AppInstallState.Idle
        val downloadVisible = download !is AppDownloadState.Idle
        val available = check is AppCheckState.UpdateAvailable && checkController.shouldPresentDialog()
        val visible = !suppressed && (installVisible || downloadVisible || available)
        val intent = when (install) {
            is AppInstallState.Confirming -> install.intent
            is AppInstallState.NeedsPermission -> install.intent
            else -> null
        }
        return AppUpdateUiState(
            currentVersion = currentVersion?.toString() ?: BuildConfig.VERSION_NAME,
            autoCheckEnabled = store.autoCheckEnabled,
            check = check,
            download = download,
            install = install,
            dialogVisible = visible,
            blockingKinds = if (installBlocking) install.blockingKinds else emptySet(),
            pendingSystemIntent = intent,
            pendingInstall = PendingInstall.fromJson(store.pendingInstallJson) != null,
        )
    }

    companion object {
        fun create(context: Context, scope: CoroutineScope): AppUpdateController =
            AppUpdateController(context.applicationContext, scope)
    }
}

/** Process-local registry; the Application owns the controller instance. */
internal object AppUpdateRuntime {
    @Volatile
    var controller: AppUpdateController? = null
}

/**
 * Scoped download lifecycle (Main critical review, 2026-10-29).
 *
 * The download engine itself is Application-scoped and durable (persisted
 * staging metadata resumes after process death). This service adds the
 * Android-owned lifecycle around it: while a download is genuinely running it
 * is a real foreground service with `foregroundServiceType="dataSync"` and an
 * ongoing progress/cancel notification, so the transfer survives screen lock
 * and ordinary backgrounding instead of relying on a plain started service
 * (which Android may stop ~1 minute after the app is backgrounded).
 *
 * It stops itself on every terminal state (Ready/Paused/Failed/Idle) and when
 * the user cancels from the notification or the dialog. It owns no work state
 * and never claims the system install confirmation: install is a separate
 * PackageInstaller flow.
 *
 * Honest platform bounds: this is not an "immortal" worker. Android 15/16
 * dataSync foreground services have a system time limit; if the platform
 * stops the service, the Application-scoped engine and its persisted staging
 * record remain the resume source. The notification is visible when the user
 * allows notifications; Android 13+ does not require POST_NOTIFICATIONS to
 * start the FGS, but a denied notification permission hides the drawer entry
 * (the FGS still runs and appears in the system task manager).
 */
class AppUpdateDownloadService : Service() {
    private var observer: Job? = null
    private var foregroundStarted = false
    private var stopping = false
    private var lastNotifiedAtMs = 0L
    private var lastNotifiedPercent = -1

    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(com.floe.android.R.string.app_update_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            // Notification action (user-initiated): stop the owned transfer and
            // this lifecycle; an already-committed install is untouched.
            AppUpdateRuntime.controller?.cancelDownload()
            stopNow()
            return START_NOT_STICKY
        }
        // Must call startForeground within the ANR window of
        // startForegroundService; the generic notification is replaced below.
        startForegroundSafely(
            buildNotification(
                text = getString(com.floe.android.R.string.app_update_notification_downloading),
                percent = null,
            ),
        )
        val controller = AppUpdateRuntime.controller
        if (controller == null) {
            stopNow()
            return START_NOT_STICKY
        }
        when (intent?.action) {
            ACTION_START -> controller.startDownloadWork()
            else -> Unit
        }
        observe(controller)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        observer?.cancel()
        observer = null
        if (foregroundStarted) runCatching { stopForeground(STOP_FOREGROUND_REMOVE) }
        foregroundStarted = false
        super.onDestroy()
    }

    private fun observe(controller: AppUpdateController) {
        observer?.cancel()
        observer = CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
            // Give the just-started work a bounded window to become active so
            // a stale terminal state from an earlier download cannot stop the
            // service immediately.
            val started = withTimeoutOrNull(60_000L) {
                controller.downloadState.first {
                    it is AppDownloadState.InProgress || it is AppDownloadState.Verifying
                }
            }
            if (started == null) {
                stopNow()
                return@launch
            }
            controller.downloadState.collect { state ->
                when (state) {
                    is AppDownloadState.InProgress -> publishProgress(state)
                    is AppDownloadState.Verifying -> publishStatus(
                        text = getString(com.floe.android.R.string.app_update_verifying),
                        percent = null,
                    )
                    is AppDownloadState.Applying -> publishStatus(
                        text = getString(com.floe.android.R.string.app_update_applying_delta),
                        percent = null,
                    )
                    is AppDownloadState.Ready,
                    is AppDownloadState.DeltaFallback,
                    is AppDownloadState.Paused,
                    is AppDownloadState.Failed,
                    is AppDownloadState.Idle -> {
                        stopNow()
                        return@collect
                    }
                }
            }
        }
    }

    private fun startForegroundSafely(notification: android.app.Notification) {
        val ok = runCatching { startForeground(NOTIFICATION_ID, notification) }.isSuccess
        foregroundStarted = ok
    }

    private fun publishProgress(state: AppDownloadState.InProgress) {
        val percent = if (state.total > 0L) {
            ((state.received * 100L) / state.total).coerceIn(0L, 100L).toInt()
        } else {
            -1
        }
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastNotifiedAtMs < 1_000L && percent == lastNotifiedPercent) return
        lastNotifiedAtMs = now
        lastNotifiedPercent = percent
        publishStatus(
            text = getString(
                com.floe.android.R.string.app_update_progress,
                state.received / 1_048_576L,
                state.total / 1_048_576L,
            ),
            percent = percent.takeIf { it >= 0 },
        )
    }

    private fun publishStatus(text: String, percent: Int?) {
        if (!foregroundStarted) return
        val notification = buildNotification(text, percent)
        runCatching {
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(text: String, percent: Int?): android.app.Notification {
        val builder = android.app.Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(getString(com.floe.android.R.string.app_update_title))
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(android.app.Notification.CATEGORY_PROGRESS)
        if (percent != null) {
            builder.setProgress(100, percent, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        val cancel = PendingIntent.getService(
            this,
            1,
            Intent(this, AppUpdateDownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        builder.addAction(
            android.app.Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(
                    this,
                    android.R.drawable.stat_sys_download,
                ),
                getString(com.floe.android.R.string.cancel),
                cancel,
            ).build(),
        )
        return builder.build()
    }

    private fun stopNow() {
        if (stopping) return
        stopping = true
        runCatching {
            if (foregroundStarted) stopForeground(STOP_FOREGROUND_REMOVE)
        }
        foregroundStarted = false
        stopSelf()
    }

    companion object {
        const val ACTION_START = "com.floe.android.host.update.action.START"
        const val ACTION_CANCEL = "com.floe.android.host.update.action.CANCEL"
        const val CHANNEL_ID = "floe_app_update_download"
        const val NOTIFICATION_ID = 0x464C4F45
    }
}
