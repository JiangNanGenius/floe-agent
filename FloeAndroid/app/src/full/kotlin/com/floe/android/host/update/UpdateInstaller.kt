// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.floe.android.runlifecycle.OperationKind
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * Install state is deliberately SEPARATE from download state. Stopping or
 * cancelling a download says nothing about a committed PackageInstaller
 * session, and the system-owned confirmation dialog is never claimed as an
 * app-side success.
 */
internal sealed interface AppInstallState {
    data object Idle : AppInstallState

    /**
     * One admission is owned and running: APK identity/checksum validation,
     * the quiescence decision, the unknown-sources handoff and the streamed
     * PackageInstaller write all happen on an owned IO job, never on the UI
     * thread (a 435 MB session write on the main thread is an ANR).
     */
    data object Preparing : AppInstallState

    /** Downloaded and verified; owned work is still running (never force-stopped). */
    data class WaitingForJobs(val blockingKinds: Set<OperationKind>) : AppInstallState

    /**
     * The OS must grant "install unknown apps" for this package first.
     *
     * Two real system surfaces are carried: the per-app unknown-sources page
     * and the App-info page. The second one is the ONLY route when Android
     * 13+ hides the first toggle behind "restricted settings" for a sideloaded
     * install; [deniedOnce] records that the user already returned without the
     * grant, and [settingsUnavailable] records that the unknown-sources page
     * could not be launched at all.
     */
    data class NeedsPermission(
        val intent: Intent,
        val appInfoIntent: Intent,
        val deniedOnce: Boolean = false,
        val settingsUnavailable: Boolean = false,
    ) : AppInstallState

    /** The verified bytes are being written into the install session. */
    data object Committing : AppInstallState

    data class AwaitingSystem(val sessionID: Int) : AppInstallState
    data class Confirming(val sessionID: Int, val intent: Intent) : AppInstallState
    data class Succeeded(val versionName: String) : AppInstallState
    data class Failed(
        val kind: InstallFailure,
        val detail: String? = null,
    ) : AppInstallState
}

/**
 * Typed install failure. The system reports enough to distinguish a cancelled
 * dialog from a blocked policy, a storage shortfall, an invalid/incompatible
 * package or a verification refusal; collapsing them into one "failed" message
 * is what left the previous flow with no actionable next step.
 */
internal enum class InstallFailure {
    CANCELLED,
    ABORTED,
    BLOCKED,
    INCOMPATIBLE,
    INVALID_PACKAGE,
    STORAGE,
    VERIFICATION,
    CONFLICT,
    SYSTEM,
    IDENTITY,
}

/**
 * Pure mapping from Android's `PackageInstaller` status to [InstallFailure].
 *
 * `status` is the value of `PackageInstaller.EXTRA_STATUS` (1..7). The legacy
 * negative `INSTALL_FAILED_*` code is carried by the platform in
 * `PackageInstaller.EXTRA_LEGACY_STATUS`; it is more specific for
 * incompatibility/verification/storage and is used when the generic status
 * alone does not identify the cause.
 */
internal object InstallFailureClassifier {
    // PackageInstaller.STATUS_* (android.content.pm.PackageInstaller).
    const val STATUS_FAILURE = 1
    const val STATUS_FAILURE_BLOCKED = 2
    const val STATUS_FAILURE_ABORTED = 3
    const val STATUS_FAILURE_INVALID = 4
    const val STATUS_FAILURE_CONFLICT = 5
    const val STATUS_FAILURE_STORAGE = 6
    const val STATUS_FAILURE_INCOMPATIBLE = 7

    // android.content.pm.PackageManager.INSTALL_FAILED_* (subset).
    const val INSTALL_FAILED_INVALID_APK = -2
    const val INSTALL_FAILED_INSUFFICIENT_STORAGE = -4
    const val INSTALL_FAILED_UPDATE_INCOMPATIBLE = -7
    const val INSTALL_FAILED_VERIFICATION_FAILURE = -22
    const val INSTALL_FAILED_ABORTED = -115

    fun classify(status: Int, legacyStatus: Int? = null): InstallFailure = when (status) {
        STATUS_FAILURE_BLOCKED -> InstallFailure.BLOCKED
        STATUS_FAILURE_ABORTED -> InstallFailure.CANCELLED
        STATUS_FAILURE_INVALID -> InstallFailure.INVALID_PACKAGE
        STATUS_FAILURE_CONFLICT -> InstallFailure.CONFLICT
        STATUS_FAILURE_STORAGE -> InstallFailure.STORAGE
        STATUS_FAILURE_INCOMPATIBLE -> InstallFailure.INCOMPATIBLE
        else -> when (legacyStatus) {
            INSTALL_FAILED_UPDATE_INCOMPATIBLE -> InstallFailure.INCOMPATIBLE
            INSTALL_FAILED_INVALID_APK -> InstallFailure.INVALID_PACKAGE
            INSTALL_FAILED_INSUFFICIENT_STORAGE -> InstallFailure.STORAGE
            INSTALL_FAILED_VERIFICATION_FAILURE -> InstallFailure.VERIFICATION
            INSTALL_FAILED_ABORTED -> InstallFailure.CANCELLED
            else -> InstallFailure.SYSTEM
        }
    }
}

/**
 * Install storage preflight. The staged APK and the PackageInstaller's own
 * copy both live on /data, so a device with "one APK" free space would pass a
 * download check and then fail inside the session with STATUS_FAILURE_STORAGE.
 * Requiring the copy plus bounded headroom turns that into an actionable state
 * before anything is committed.
 */
internal object InstallStoragePolicy {
    fun requiredBytes(apkBytes: Long): Long {
        if (apkBytes <= 0L) return UpdateConfig.INSTALL_HEADROOM_BYTES
        val tenPercent = apkBytes / 10L
        return apkBytes + maxOf(UpdateConfig.INSTALL_HEADROOM_BYTES, tenPercent)
    }

    fun hasRoom(usableSpace: Long, apkBytes: Long): Boolean {
        if (usableSpace <= 0L) return true // unknown reporting: defer to the OS
        return usableSpace >= requiredBytes(apkBytes)
    }
}

/** Persisted record of one committed install session (process-death safe). */
internal data class PendingInstall(
    val versionName: String,
    val versionCode: Long,
    val sha256: String,
    val fileName: String,
    val sessionID: Int,
    val packageName: String = "",
    val signerSha256: Set<String> = emptySet(),
) {
    fun toJson(): String = buildJsonObject {
        put("versionName", versionName)
        put("versionCode", versionCode)
        put("sha256", sha256)
        put("fileName", fileName)
        put("sessionID", sessionID)
        put("packageName", packageName)
        put("signerSha256", signerSha256.sorted().joinToString(","))
    }.toString()

    companion object {
        fun fromJson(text: String?): PendingInstall? {
            if (text.isNullOrBlank()) return null
            val obj = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            fun string(key: String): String? =
                (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val versionName = string("versionName") ?: return null
            val versionCode = (obj["versionCode"] as? JsonPrimitive)?.longOrNull ?: return null
            val sha256 = string("sha256") ?: return null
            val fileName = string("fileName") ?: return null
            val sessionID = (obj["sessionID"] as? JsonPrimitive)?.intOrNull ?: return null
            if (versionCode <= 0L || sessionID <= 0) return null
            if (!sha256.matches(Regex("[0-9a-f]{64}"))) return null
            if (fileName.isEmpty() || fileName.contains('/') || fileName.contains('\\')) return null
            val packageName = string("packageName").orEmpty()
            if (packageName.length > 200 || packageName.contains('/') || packageName.contains('\\')) return null
            val signers = string("signerSha256")
                .orEmpty()
                .split(',')
                .filter { it.isNotEmpty() }
                .toSet()
            if (signers.any { !it.matches(Regex("[0-9a-f]{64}")) }) return null
            return PendingInstall(
                versionName = versionName,
                versionCode = versionCode,
                sha256 = sha256,
                fileName = fileName,
                sessionID = sessionID,
                packageName = packageName,
                signerSha256 = signers,
            )
        }
    }
}

/** Process-local handoff of PackageInstaller callbacks (never exposed to a model). */
internal sealed interface InstallEvent {
    data class Confirmation(val sessionID: Int, val intent: Intent) : InstallEvent
    data class Finished(
        val sessionID: Int,
        val success: Boolean,
        val status: Int,
        val legacyStatus: Int? = null,
    ) : InstallEvent
}

internal object AppUpdateInstallEvents {
    private val mutable = MutableStateFlow<InstallEvent?>(null)
    val events: Flow<InstallEvent?> = mutable.asStateFlow()

    fun publish(event: InstallEvent) {
        mutable.value = event
    }

    /** Latest process-local callback, used by startup reconciliation. */
    fun current(): InstallEvent? = mutable.value
}

/**
 * Self-update install path. Uses the same legitimate Android installer
 * plumbing as the bundled-runtime path (canRequestPackageInstalls ->
 * PackageInstaller session -> explicit private callback) but with its OWN
 * identity extras and its own state: an app self-update is not a runtime
 * child install and the two must never be conflated.
 *
 * Threading (Main critical review, 2026-10-29): every blocking step —
 * PackageManager APK identity parsing, ZIP/ABI inspection, quiescence wait,
 * the SHA-256 computation and the streamed session write of the (tens to
 * hundreds of MB) APK plus fsync — runs on an owned [Dispatchers.IO] job.
 * [requestInstall] only performs the in-memory state admission on the caller
 * (UI) thread, so a Samsung-class device never freezes or ANRs during the
 * install handoff.
 *
 * Integrity: the release SHA-256 that the downloader verified is RE-CHECKED
 * over the exact bytes streamed into the session, and the package/version/
 * signer identity is re-read immediately before the commit, so a proof that
 * was true when the download finished cannot become stale across a
 * quiescence wait or the unknown-sources round trip. A digest mismatch
 * abandons the session before any commit.
 *
 * Recovery: a verified staging APK is NEVER deleted by a failed or cancelled
 * install attempt — only by an explicit discard or after a confirmed success.
 * When the system ends an owned session without a result (or its confirmation
 * intent can no longer be launched), the user can cancel the owned session and
 * retry from the SAME verified bytes instead of re-downloading a full APK.
 */
internal class AppUpdateInstaller(
    private val context: Context,
    private val scope: CoroutineScope,
    private val store: UpdateStore,
    private val reader: ApkIdentityReader,
    private val stagingDir: File,
    private val heldOperationKinds: () -> Set<OperationKind>,
) {
    private val mutable = MutableStateFlow<AppInstallState>(AppInstallState.Idle)
    val state = mutable.asStateFlow()
    private val waitingJob = AtomicReference<Job?>(null)

    /** One admission at a time; the UI never owns the blocking work. */
    private val admissionHeld = AtomicBoolean(false)

    @Volatile
    private var permissionPending: PendingInstallRequest? = null

    @Volatile
    private var permissionDeniedOnce: Boolean = false

    private data class PendingInstallRequest(
        val versionName: String,
        val apk: File,
        val sha256: String,
    )

    init {
        scope.launch {
            AppUpdateInstallEvents.events.collect { event ->
                if (event != null) handleEvent(event)
            }
        }
    }

    /**
     * Process-restart reconciliation: the installed versionCode is the truth.
     * A leftover session with no record is explicitly abandoned (never left to
     * occupy storage silently).
     */
    fun reconcile() {
        val record = PendingInstall.fromJson(store.pendingInstallJson)
        if (record == null) {
            abandonOrphanSessions()
            return
        }
        // A real system confirmation may already have been delivered while the
        // process was starting (the broadcast starts the Application, then the
        // event is retained in the StateFlow). Never overwrite that actionable
        // Confirming state with a generic AwaitingSystem.
        when (val current = mutable.value) {
            is AppInstallState.Confirming,
            is AppInstallState.Succeeded,
            is AppInstallState.Failed -> return
            else -> Unit
        }
        when (val pending = AppUpdateInstallEvents.current()) {
            is InstallEvent.Confirmation -> if (pending.sessionID == record.sessionID) {
                mutable.value = AppInstallState.Confirming(pending.sessionID, pending.intent)
                return
            }
            is InstallEvent.Finished -> if (pending.sessionID == record.sessionID) {
                handleEvent(pending)
                return
            }
            null -> Unit
        }
        val installed = reader.installed()
        if (installed != null && installed.longVersionCode >= record.versionCode) {
            adoptInstalled(record, installed)
            return
        }
        val session = runCatching {
            context.packageManager.packageInstaller.mySessions
                .firstOrNull { it.sessionId == record.sessionID }
        }.getOrNull()
        if (session != null) {
            // The session is still owned by the system. If its confirmation
            // callback was lost across process death, the UI offers an explicit
            // "cancel pending install" action (never a silent duplicate).
            mutable.value = AppInstallState.AwaitingSystem(record.sessionID)
        } else {
            store.pendingInstallJson = null
            mutable.value = AppInstallState.Failed(InstallFailure.ABORTED, "session-ended")
        }
    }

    /**
     * Explicit user recovery for an owned session whose system confirmation is
     * no longer actionable in this process. Abandons ONLY this app's recorded
     * session and clears the persisted record: never starts a new install and
     * never deletes a successful installed package. The verified staging APK
     * is KEPT so the user can retry without a new download.
     */
    fun cancelPendingInstall() {
        val record = PendingInstall.fromJson(store.pendingInstallJson) ?: return
        val installed = reader.installed()
        if (installed != null && installed.longVersionCode >= record.versionCode) {
            adoptInstalled(record, installed)
            return
        }
        val abandoned = runCatching {
            context.packageManager.packageInstaller.abandonSession(record.sessionID)
        }.isSuccess
        if (!abandoned) {
            mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "pending-session-abandon-failed")
            return
        }
        store.pendingInstallJson = null
        permissionPending = null
        mutable.value = AppInstallState.Failed(InstallFailure.CANCELLED, "pending-cancelled")
    }

    /**
     * Retry the installation from the already-verified staging APK after a
     * failure that did NOT leave an owned pending session (storage, identity,
     * output verification, a session ended by the system, or a permission
     * handoff that could not be launched). The full admission — identity,
     * signer, quiescence, permission and the streamed checksum — runs again.
     *
     * This never re-commits an ambiguous session: a persisted record blocks
     * the retry and must be resolved through reconcile/cancel first.
     */
    fun retryInstall(versionName: String, apk: File, sha256: String) {
        if (mutable.value !is AppInstallState.Failed) return
        if (PendingInstall.fromJson(store.pendingInstallJson) != null) return
        // Only sessions that were never committed have no record; abandoning
        // them here is the explicit cleanup before a fresh admission.
        abandonOrphanSessions()
        mutable.value = AppInstallState.Idle
        requestInstall(versionName, apk, sha256, force = false)
    }

    /**
     * UI-thread admission only: one in-memory state transition plus the owned
     * IO job. All validation/copy work (including the 435 MB stream and its
     * fsync) happens off the main thread.
     *
     * @param force explicit user "install now" choice; it skips the waiting
     *   gate only. Identity, signer, checksum and permission checks always
     *   run.
     */
    fun requestInstall(versionName: String, apk: File, sha256: String, force: Boolean) {
        when (mutable.value) {
            is AppInstallState.Preparing,
            is AppInstallState.Committing,
            is AppInstallState.AwaitingSystem,
            is AppInstallState.Confirming -> return
            else -> Unit
        }
        // A persisted install session means an earlier commit already handed
        // (or may have handed) ownership to the system. Never resubmit an
        // ambiguous commit: reconcile/confirmation must resolve that session.
        if (PendingInstall.fromJson(store.pendingInstallJson) != null) {
            mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "session-pending")
            return
        }
        if (!admissionHeld.compareAndSet(false, true)) return
        if (!sha256.matches(Regex("[0-9a-f]{64}"))) {
            admissionHeld.set(false)
            mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, "missing-release-checksum")
            return
        }
        cancelWaiting()
        mutable.value = AppInstallState.Preparing
        val request = PendingInstallRequest(versionName, apk, sha256.lowercase())
        permissionPending = request
        scope.launch(Dispatchers.IO) {
            try {
                admit(request, force)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Exception) {
                mutable.value = AppInstallState.Failed(
                    InstallFailure.SYSTEM,
                    "admission-${failure.javaClass.simpleName}",
                )
            } finally {
                admissionHeld.set(false)
            }
        }
    }

    /**
     * Owned IO admission. Identity and checksum are validated here (after any
     * wait already elapsed) and revalidated once more inside [commit], directly
     * before the PackageInstaller commit.
     */
    private fun admit(request: PendingInstallRequest, force: Boolean) {
        val apk = request.apk
        if (!apk.isFile || apk.length() <= 0L) {
            mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, "missing-package")
            return
        }
        val rejection = reader.rejectionFor(apk)
        if (rejection != null) {
            mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, rejection.name.lowercase())
            return
        }
        if (!force) {
            val kinds = heldOperationKinds()
            if (kinds.isNotEmpty()) {
                mutable.value = AppInstallState.WaitingForJobs(kinds)
                startWaiting(request)
                return
            }
        }
        cancelWaiting()
        permissionPending = request
        if (!context.packageManager.canRequestPackageInstalls()) {
            mutable.value = permissionState(deniedOnce = permissionDeniedOnce)
            return
        }
        permissionDeniedOnce = false
        // Both the staged APK and the installer's own copy live on /data.
        if (!InstallStoragePolicy.hasRoom(stagingDir.usableSpace, apk.length())) {
            mutable.value = AppInstallState.Failed(InstallFailure.STORAGE, "install-space")
            return
        }
        commit(request)
    }

    private fun permissionState(
        deniedOnce: Boolean,
        settingsUnavailable: Boolean = false,
    ): AppInstallState.NeedsPermission {
        val packageUri = Uri.parse("package:${context.packageName}")
        return AppInstallState.NeedsPermission(
            intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, packageUri)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            appInfoIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            deniedOnce = deniedOnce,
            settingsUnavailable = settingsUnavailable,
        )
    }

    /** Resume after the user returns from the unknown-sources/App-info settings. */
    fun onForeground() {
        when (val current = mutable.value) {
            is AppInstallState.NeedsPermission -> {
                val pending = permissionPending ?: return
                if (!context.packageManager.canRequestPackageInstalls()) {
                    // Returning without the grant is a real state: keep the two
                    // actionable system surfaces and say the toggle is still off
                    // (on Android 13+ it may be hidden by restricted settings).
                    permissionDeniedOnce = true
                    mutable.value = permissionState(
                        deniedOnce = true,
                        settingsUnavailable = current.settingsUnavailable,
                    )
                    return
                }
                permissionDeniedOnce = false
                // Re-enter the full admission: identity, release SHA and the
                // quiescence state are re-proved after the settings round trip.
                requestInstall(pending.versionName, pending.apk, pending.sha256, force = false)
            }
            is AppInstallState.WaitingForJobs -> {
                if (heldOperationKinds().isEmpty()) {
                    val pending = permissionPending ?: return
                    requestInstall(pending.versionName, pending.apk, pending.sha256, force = false)
                }
            }
            is AppInstallState.AwaitingSystem -> refreshSession(current.sessionID)
            else -> Unit
        }
    }

    /**
     * The unknown-sources Settings page could not be launched on this build.
     * Keep the state actionable by switching the primary surface to App info
     * and marking the page unavailable instead of leaving a dead button.
     */
    fun onPermissionIntentUnavailable() {
        if (mutable.value !is AppInstallState.NeedsPermission) return
        mutable.value = permissionState(deniedOnce = true, settingsUnavailable = true)
    }

    fun cancelWaiting() {
        waitingJob.getAndSet(null)?.cancel()
        if (mutable.value is AppInstallState.WaitingForJobs) {
            mutable.value = AppInstallState.Idle
            permissionPending = null
        }
    }

    /** Only a visible user click may launch this intent. */
    fun consumeConfirmation(): Intent? {
        val current = mutable.value as? AppInstallState.Confirming ?: return null
        mutable.value = AppInstallState.AwaitingSystem(current.sessionID)
        return current.intent
    }

    /**
     * The system confirmation intent could not be launched. The owned session
     * still exists and still blocks a duplicate commit; the explicit recovery
     * is "cancel install" followed by a retry from the same verified APK.
     */
    fun onConfirmationUnavailable() {
        if (mutable.value is AppInstallState.Confirming) {
            mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "confirmation-unavailable")
        }
    }

    fun dismissFailure() {
        if (mutable.value is AppInstallState.Failed) mutable.value = AppInstallState.Idle
    }

    fun clearSucceeded() {
        if (mutable.value is AppInstallState.Succeeded) mutable.value = AppInstallState.Idle
    }

    /**
     * Bounded quiescence wait on an owned coroutine. When it drains, a NEW
     * admission revalidates everything before commit (see [admit]). Reaching
     * the deadline does not commit and does not spin: the explicit "install
     * now" action remains the only way past a still-busy device.
     */
    private fun startWaiting(request: PendingInstallRequest) {
        if (waitingJob.get() != null) return
        val job = scope.launch(Dispatchers.Default) {
            try {
                val deadline = System.currentTimeMillis() + UpdateConfig.QUIESCENCE_WAIT_MS
                while (isActive && System.currentTimeMillis() < deadline) {
                    delay(2_000L)
                    if (mutable.value !is AppInstallState.WaitingForJobs) return@launch
                    val kinds = heldOperationKinds()
                    if (kinds.isEmpty()) {
                        waitingJob.set(null)
                        requestInstall(request.versionName, request.apk, request.sha256, force = false)
                        return@launch
                    }
                    mutable.value = AppInstallState.WaitingForJobs(kinds)
                }
                // Deadline reached with work still owned: stay in the explicit
                // waiting state (no commit, no infinite loop, no false success).
                if (mutable.value is AppInstallState.WaitingForJobs) {
                    mutable.value = AppInstallState.WaitingForJobs(heldOperationKinds())
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } finally {
                val self = kotlinx.coroutines.currentCoroutineContext()[Job]
                if (waitingJob.get() === self) waitingJob.set(null)
            }
        }
        waitingJob.set(job)
        job.invokeOnCompletion { if (waitingJob.get() === job) waitingJob.set(null) }
    }

    /**
     * Streams the verified staging APK into a private PackageInstaller session
     * on the owned IO job. The digest is computed over the exact bytes written;
     * a mismatch abandons the session BEFORE commit. Only the final
     * [PackageInstaller.Session.commit] hands ownership to the system.
     */
    private fun commit(request: PendingInstallRequest) {
        val apk = request.apk
        // Re-read identity at the commit boundary: a proof that was true when
        // the download completed (or before the permission round trip) must
        // not be assumed to still hold.
        val candidate = reader.read(apk)
        if (candidate == null) {
            mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, "not-an-apk")
            return
        }
        val rejection = reader.rejectionFor(apk)
        if (rejection != null) {
            mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, rejection.name.lowercase())
            return
        }
        val packageInstaller = context.packageManager.packageInstaller
        mutable.value = AppInstallState.Committing
        // Explicit retry may replace only this app's own unfinished session;
        // installed data is never touched by an app-side update.
        runCatching {
            packageInstaller.mySessions
                .filter { it.appPackageName == context.packageName }
                .forEach { packageInstaller.abandonSession(it.sessionId) }
        }
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL,
        ).apply {
            setAppPackageName(context.packageName)
            setSize(apk.length())
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
            }
        }
        val sessionID = try {
            packageInstaller.createSession(params)
        } catch (failure: Exception) {
            mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "session-create")
            return
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val session = try {
            packageInstaller.openSession(sessionID)
        } catch (failure: Exception) {
            runCatching { packageInstaller.abandonSession(sessionID) }
            mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "session-open")
            return
        }
        var committed = false
        try {
            session.openWrite("app-update.apk", 0L, apk.length()).use { output ->
                apk.inputStream().use { input ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                }
                session.fsync(output)
            }
            val streamedSha = digest.digest().joinToString("") { "%02x".format(it) }
            if (!streamedSha.equals(request.sha256, ignoreCase = true)) {
                // The staged bytes are not the release artifact the feed
                // proved. Abandon before commit; nothing was installed.
                store.pendingInstallJson = null
                runCatching { session.abandon() }
                runCatching { session.close() }
                mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, "release-checksum")
                return
            }
            // Identity is re-read at the last moment before commit; the
            // system installer independently enforces package/version/
            // signature, but the UI never adopts an install whose local
            // admission proof went stale.
            val post = reader.read(apk)
            if (post == null || post.packageName != candidate.packageName ||
                post.longVersionCode != candidate.longVersionCode ||
                post.signerSha256 != candidate.signerSha256
            ) {
                store.pendingInstallJson = null
                runCatching { session.abandon() }
                runCatching { session.close() }
                mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, "artifact-changed")
                return
            }
            val callback = PendingIntent.getBroadcast(
                context,
                sessionID,
                Intent(context, AppUpdateInstallReceiver::class.java)
                    .putExtra(EXTRA_SESSION_ID, sessionID),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            // Persist BEFORE the commit callback can be delivered so no
            // system confirmation is ever dropped as an unknown session.
            store.pendingInstallJson = PendingInstall(
                versionName = request.versionName,
                versionCode = post.longVersionCode,
                sha256 = streamedSha,
                fileName = apk.name,
                sessionID = sessionID,
                packageName = post.packageName,
                signerSha256 = post.signerSha256,
            ).toJson()
            // Hand ownership to the system exactly once. An exception here is
            // an AMBIGUOUS commit: keep the persisted session record and the
            // open session (never abandon, never resubmit), so a later
            // confirmation or process reconcile can adopt the real outcome.
            try {
                session.commit(callback.intentSender)
                committed = true
            } catch (failure: Exception) {
                mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "commit-unknown")
                return
            }
        } catch (failure: Exception) {
            // Only pre-commit work reaches here (commit has its own handling).
            if (!committed) {
                store.pendingInstallJson = null
                runCatching { session.abandon() }
                runCatching { session.close() }
            }
            mutable.value = AppInstallState.Failed(InstallFailure.SYSTEM, "session-commit")
            return
        }
        if (committed) runCatching { session.close() }
        permissionPending = null
        mutable.value = AppInstallState.AwaitingSystem(sessionID)
    }

    private fun handleEvent(event: InstallEvent) {
        val record = PendingInstall.fromJson(store.pendingInstallJson) ?: return
        when (event) {
            is InstallEvent.Confirmation -> {
                if (event.sessionID == record.sessionID) {
                    mutable.value = AppInstallState.Confirming(record.sessionID, event.intent)
                }
            }
            is InstallEvent.Finished -> {
                if (event.sessionID != record.sessionID) return
                if (event.success) {
                    val installed = reader.installed()
                    if (installed != null) {
                        // adoptInstalled retires the consumed download and then
                        // clears this install record, so a crash between the
                        // two durable writes still leaves a record that
                        // re-adopts and finishes the cleanup.
                        adoptInstalled(record, installed)
                    } else {
                        // The system reported success for our own verified
                        // session; keep the honest success result and retire
                        // only the exact consumed target. Installed identity
                        // was not readable, so no identity claim is made.
                        retireConsumedDownload(record)
                        store.pendingInstallJson = null
                        mutable.value = AppInstallState.Succeeded(record.versionName)
                        cleanupStaged(record)
                    }
                } else {
                    store.pendingInstallJson = null
                    val kind = InstallFailureClassifier.classify(event.status, event.legacyStatus)
                    runCatching { context.packageManager.packageInstaller.abandonSession(record.sessionID) }
                    // The verified staging APK is retained for an explicit retry.
                    mutable.value = AppInstallState.Failed(kind, "status-${event.status}")
                }
            }
        }
    }

    private fun adoptInstalled(record: PendingInstall, installed: ApkIdentity) {
        if (!UpdateSettlementPolicy.installedMatchesRecord(installed, record)) {
            store.pendingInstallJson = null
            val detail = if (record.packageName.isNotEmpty() && installed.packageName != record.packageName) {
                "installed-package-changed"
            } else {
                "installed-signer-changed"
            }
            mutable.value = AppInstallState.Failed(InstallFailure.IDENTITY, detail)
            return
        }
        // Retire the completed download that this install consumed BEFORE the
        // install record: the process is killed by the system right after a
        // self-update, and a leftover completed download record would be
        // re-admitted on the next start against the now-equal installed
        // version (VERSION_NOT_HIGHER -> false "mismatch"). If that kill lands
        // between these writes, the surviving install record is enough for the
        // next reconcile to repeat adoption and finish the cleanup.
        retireConsumedDownload(record)
        store.pendingInstallJson = null
        mutable.value = AppInstallState.Succeeded(
            if (installed.longVersionCode == record.versionCode && record.versionName.isNotEmpty()) {
                record.versionName
            } else {
                installed.versionName.ifEmpty { record.versionName }
            },
        )
        cleanupStaged(record)
    }

    /**
     * Clears ONE durable download record, and only when it is the exact
     * target (file name, version name and release SHA-256) that the settled
     * install streamed into its PackageInstaller session. A different or
     * newer download is left untouched.
     */
    private fun retireConsumedDownload(record: PendingInstall) {
        val meta = DownloadMeta.fromJson(store.pendingDownloadJson) ?: return
        if (UpdateSettlementPolicy.isConsumedDownload(meta, record)) {
            store.pendingDownloadJson = null
        }
    }

    private fun refreshSession(sessionID: Int) {
        val present = runCatching {
            context.packageManager.packageInstaller.mySessions.any { it.sessionId == sessionID }
        }.getOrDefault(true)
        if (present) return
        val record = PendingInstall.fromJson(store.pendingInstallJson)
        val installed = reader.installed()
        if (record != null && installed != null && installed.longVersionCode >= record.versionCode) {
            adoptInstalled(record, installed)
        } else if (record != null) {
            store.pendingInstallJson = null
            mutable.value = AppInstallState.Failed(InstallFailure.ABORTED, "session-ended")
        }
    }

    private fun abandonOrphanSessions() {
        runCatching {
            val packageInstaller = context.packageManager.packageInstaller
            packageInstaller.mySessions
                .filter { it.appPackageName == context.packageName }
                .forEach { packageInstaller.abandonSession(it.sessionId) }
        }
    }

    /**
     * Deletes ONLY the exact staged file of a confirmed install. Other staged
     * files are owned by the downloader and are never touched from here (a
     * concurrent writer or a delta fallback must not lose its bytes).
     */
    private fun cleanupStaged(record: PendingInstall) {
        runCatching { File(stagingDir, record.fileName).delete() }
    }

    companion object {
        /** Distinct from the bundled-runtime installer's private extra. */
        const val EXTRA_SESSION_ID = "floeAppUpdateSessionID"
    }
}

/** Private callback: the pending confirmation intent is never exposed to a model. */
class AppUpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val sessionID = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        if (sessionID <= 0 || sessionID != intent.getIntExtra(AppUpdateInstaller.EXTRA_SESSION_ID, -2)) {
            return
        }
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (confirmation != null) {
                    AppUpdateInstallEvents.publish(
                        InstallEvent.Confirmation(sessionID, confirmation),
                    )
                }
                // The visible foreground UI presents the system confirmation;
                // a broadcast never launches an Activity from the background.
            }
            PackageInstaller.STATUS_SUCCESS -> AppUpdateInstallEvents.publish(
                InstallEvent.Finished(sessionID, success = true, status = status),
            )
            else -> AppUpdateInstallEvents.publish(
                InstallEvent.Finished(
                    sessionID = sessionID,
                    success = false,
                    status = status,
                    legacyStatus = intent.getIntExtra(
                        "android.content.pm.extra.LEGACY_STATUS", // wire extra; no public SDK constant
                        Int.MIN_VALUE,
                    ).takeIf { it != Int.MIN_VALUE },
                ),
            )
        }
    }
}
