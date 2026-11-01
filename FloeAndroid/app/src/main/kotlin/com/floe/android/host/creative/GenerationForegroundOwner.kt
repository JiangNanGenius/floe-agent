// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.floe.android.bridge.GenerationForegroundNative
import com.floe.android.feature.canvas.CreativeAvailability
import com.floe.android.feature.workbench.CreativeProjectContext
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Exact native job identity for an App foreground claim. [token] is the opaque
 * service-start identity, never a client root/session. The separate
 * notification-return token is minted and retained only inside the owner and
 * is never exposed through this object.
 */
data class GenerationForegroundClaim(
    val jobID: String,
    val epoch: Long,
    val projectID: String,
    val token: String,
)

/** Injectable foreground seam: production is [GenerationForegroundOwner]. */
interface GenerationForegroundPort {
    suspend fun acquire(jobID: String, epoch: Long, projectID: String): GenerationForegroundClaim?
    fun release(claim: GenerationForegroundClaim?)
    fun release(jobID: String, epoch: Long)
    fun cancel(jobID: String, epoch: Long)
    fun releaseAll(epoch: Long)

    /**
     * Optional return-context capture. Production retains the exact accepted
     * [CreativeProjectContext] (project + explicit storage + origin) for the
     * notification return; an injected mock keeps the default no-op so no
     * existing test double breaks.
     */
    fun captureReturnContext(
        claim: GenerationForegroundClaim,
        context: CreativeProjectContext,
    ): Boolean = false
}

/**
 * Process-wide owner of the bounded cloud-generation `dataSync` foreground
 * service.
 *
 * The actual OS ownership is [GenerationForegroundService]. This object only:
 *  * keeps the exact captured native job UUID + generation epoch + project;
 *  * starts the service for an explicit user-visible generation action and
 *    waits for a REAL `startForeground` confirmation before registering the
 *    native lease;
 *  * reports a definite denial to native when the start cannot be honest, so
 *    no paid provider request is dispatched;
 *  * pumps native durable state for progress/Cancel/timeout and releases the
 *    exact lease only after the notification service stopped.
 *
 * It is NOT a project/task/job store. [initializeApplicationContext] is
 * data-only: no channel, service or permission is touched until a real job
 * acquires.
 */
object GenerationForegroundOwner : GenerationForegroundPort {
    const val ACTION_START = "com.floe.android.host.creative.GENERATION_FOREGROUND_START"
    const val ACTION_CANCEL_ALL = "com.floe.android.host.creative.GENERATION_FOREGROUND_CANCEL"
    const val EXTRA_TOKEN = "com.floe.android.host.creative.GENERATION_FOREGROUND_TOKEN"

    /** Android 15+ dataSync budget for one app in 24h. */
    const val MAX_DATA_SYNC_MILLIS = GenerationReturnNavigation.CLAIM_TTL_MILLIS
    const val MAX_CLAIMS = 8
    private const val CHANNEL_ID = "floe_generation_foreground"
    private const val NOTIFICATION_ID = 0x46474E31 // "FGN1"
    private const val CONFIRM_TIMEOUT_MILLIS = 6_000L

    private class Claim(
        val jobID: String,
        val epoch: Long,
        val projectID: String,
        val token: String,
        val startedAt: Long,
        val confirmed: CompletableDeferred<Boolean> = CompletableDeferred(),
    ) {
        /**
         * Opaque notification-return identity, distinct from the service
         * start token. It is never exposed through the foreground port, never
         * persisted and never accepted as a path/project authorization.
         */
        val returnToken: String = UUID.randomUUID().toString().lowercase()

        /**
         * The exact accepted project context (storage/origin) captured after
         * the native register succeeded. Bounded by the claim itself; it is
         * dropped with the claim on terminal/root/expiration.
         */
        @Volatile var returnContext: GenerationReturnContext? = null
        @Volatile var registered: Boolean = false
        @Volatile var lastState: String = "preparing"
        @Volatile var progress: Double? = null
    }

    private val lock = Any()
    private val byToken = LinkedHashMap<String, Claim>()
    private val byJob = HashMap<String, Claim>()
    private val byReturnToken = HashMap<String, Claim>()

    @Volatile private var applicationContext: Context? = null

    /** Data-only application context capture; safe to call repeatedly. */
    fun initializeApplicationContext(context: Context) {
        if (applicationContext == null) {
            applicationContext = context.applicationContext
        }
    }

    val isInitialized: Boolean get() = applicationContext != null

    private fun key(jobID: String, epoch: Long) = "$epoch|${jobID.lowercase()}"

    private fun publicClaim(claim: Claim) = GenerationForegroundClaim(
        jobID = claim.jobID, epoch = claim.epoch,
        projectID = claim.projectID, token = claim.token)

    /**
     * SERVICE-START ONLY: the foreground service resolves its own opaque start
     * token to confirm that an exact claim still exists. This is NOT
     * navigation authority — it can return before the native lease registers.
     * Notification return always goes through [resolveReturn].
     */
    fun claimForStart(token: String): GenerationForegroundClaim? =
        synchronized(lock) { byToken[token]?.let(::publicClaim) }

    /**
     * Retains the exact accepted project context for notification return.
     *
     * Only the claim object actually returned by a confirmed [acquire] can
     * attach it; the token/job/epoch/project must still match the same live
     * claim, the claim must be REGISTERED by the native lease, and the context
     * cannot be rebound later. An injected/mock claim, a service-start-only
     * claim or a stale epoch returns false and never becomes navigation.
     */
    override fun captureReturnContext(
        claim: GenerationForegroundClaim,
        context: CreativeProjectContext,
    ): Boolean {
        val storage = context.storage
        val origin = context.origin
        if (!isExplicitReturnStorage(storage)) return false
        if (origin != null && !origin.isValid()) return false
        var freshlyAttached = false
        val accepted = synchronized(lock) {
            val owned = byToken[claim.token] ?: return false
            if (!owned.registered) return false
            if (owned.jobID != claim.jobID.lowercase()) return false
            if (owned.epoch != claim.epoch) return false
            if (owned.projectID != claim.projectID.lowercase()) return false
            // The captured context must be the SAME accepted project the
            // registered claim belongs to; no context rebind is possible.
            if (!owned.projectID.equals(context.projectID, ignoreCase = true)) {
                return false
            }
            val next = GenerationReturnContext(storage = storage, origin = origin)
            val current = owned.returnContext
            if (current == null) {
                owned.returnContext = next
                freshlyAttached = true
                true
            } else {
                current == next
            }
        }
        if (freshlyAttached) {
            // The notification only advertises the opaque return identity
            // once the exact accepted context exists, so a tap can never
            // resolve to an unopenable token window.
            updateNotification(applicationContext)
        }
        return accepted
    }

    /**
     * Resolve the opaque notification token to the exact registered live
     * claim and its captured accepted context, then require the current
     * native bound epoch to still equal the claim's accepted generation epoch.
     *
     * A cold process has no RAM claim, so its token resolves to UNKNOWN_TOKEN
     * and nothing is routed or resurrected.
     */
    fun resolveReturn(
        token: String?,
        nowElapsedMillis: Long,
        liveEpoch: Long?,
        availability: CreativeAvailability,
    ): GenerationReturnDecision {
        val opaque = token?.takeIf { isOpaqueGenerationToken(it) } ?: run {
            return GenerationReturnDecision.Rejected(
                GenerationReturnRejection.INVALID_REQUEST)
        }
        val snapshot = synchronized(lock) {
            val claim = byReturnToken[opaque] ?: return@synchronized null
            GenerationReturnClaimSnapshot(
                token = claim.returnToken,
                jobID = claim.jobID,
                epoch = claim.epoch,
                projectID = claim.projectID,
                registered = claim.registered,
                storage = claim.returnContext?.storage,
                origin = claim.returnContext?.origin,
                startedAtElapsedMillis = claim.startedAt,
            )
        }
        return authorizeGenerationReturn(
            requestToken = opaque,
            claim = snapshot,
            nowElapsedMillis = nowElapsedMillis,
            liveEpoch = liveEpoch,
            availability = availability,
        )
    }

    override suspend fun acquire(
        jobID: String,
        epoch: Long,
        projectID: String,
    ): GenerationForegroundClaim? {
        val context = applicationContext ?: return null
        if (epoch <= 0L) return null
        val uuid = runCatching { UUID.fromString(jobID) }.getOrNull() ?: return null
        if (runCatching { UUID.fromString(projectID) }.getOrNull() == null) return null
        val normalizedJob = uuid.toString().lowercase()
        var atCapacity = false
        synchronized(lock) {
            byJob[key(normalizedJob, epoch)]?.let { existing ->
                // Only a CONFIRMED/registered claim is reusable; a concurrent
                // first acquire keeps waiting and owns the native lease.
                return if (existing.registered) publicClaim(existing) else null
            }
            atCapacity = byToken.size >= MAX_CLAIMS
        }
        if (atCapacity) {
            GenerationForegroundNative.deny(
                normalizedJob, epoch, "foregroundCapacity")
            return null
        }
        if (!notificationsUsable(context)) {
            GenerationForegroundNative.deny(normalizedJob, epoch, "notificationsBlocked")
            return null
        }
        if (!ensureChannel(context)) {
            GenerationForegroundNative.deny(normalizedJob, epoch, "notificationsBlocked")
            return null
        }
        val token = UUID.randomUUID().toString().lowercase()
        val claim = Claim(
            jobID = normalizedJob, epoch = epoch, projectID = projectID.lowercase(),
            token = token, startedAt = SystemClock.elapsedRealtime())
        synchronized(lock) {
            val existing = byJob[key(normalizedJob, epoch)]
            if (existing != null) return publicClaim(existing)
            byToken[token] = claim
            byJob[key(normalizedJob, epoch)] = claim
            byReturnToken[claim.returnToken] = claim
        }
        val intent = Intent(context, GenerationForegroundService::class.java).apply {
            action = ACTION_START
            putExtra(EXTRA_TOKEN, token)
        }
        val started = try {
            ContextCompat.startForegroundService(context, intent)
            true
        } catch (_: Throwable) {
            false
        }
        if (!started) {
            removeClaim(claim)
            GenerationForegroundNative.deny(normalizedJob, epoch, "startDenied")
            stopServiceIfIdle(context)
            return null
        }
        val confirmed = try {
            withTimeoutOrNull(CONFIRM_TIMEOUT_MILLIS) {
                claim.confirmed.await()
            } ?: false
        } catch (cancelled: CancellationException) {
            // The caller was cancelled while waiting. The service may already
            // be live, so release this exact claim before propagating.
            removeClaim(claim)
            GenerationForegroundNative.deny(
                normalizedJob, epoch, "startCancelled")
            stopServiceIfIdle(context)
            throw cancelled
        }
        if (!confirmed) {
            removeClaim(claim)
            GenerationForegroundNative.deny(normalizedJob, epoch, "startDenied")
            stopServiceIfIdle(context)
            return null
        }
        val stillOwned = synchronized(lock) { byToken[token] === claim }
        if (!stillOwned) {
            GenerationForegroundNative.release(normalizedJob, epoch, token)
            stopServiceIfIdle(context)
            return null
        }
        val registered = try {
            GenerationForegroundNative.register(
                normalizedJob, epoch, projectID.lowercase(), token)
        } catch (failure: Throwable) {
            removeClaim(claim)
            GenerationForegroundNative.release(normalizedJob, epoch, token)
            stopServiceIfIdle(context)
            return null
        }
        if (registered != 0) {
            removeClaim(claim)
            GenerationForegroundNative.deny(
                normalizedJob, epoch, "foregroundLeaseRejected")
            stopServiceIfIdle(context)
            return null
        }
        // A concurrent terminal release/cancel may have removed the local
        // claim while the native register was in flight. Never leave a native
        // lease without the exact local owner.
        var stillOwnedAfterRegister = false
        synchronized(lock) {
            if (byToken[token] === claim) {
                claim.registered = true
                stillOwnedAfterRegister = true
            }
        }
        if (!stillOwnedAfterRegister) {
            GenerationForegroundNative.release(normalizedJob, epoch, token)
            stopServiceIfIdle(context)
            return null
        }
        updateNotification(context)
        return publicClaim(claim)
    }

    override fun release(claim: GenerationForegroundClaim?) {
        if (claim == null) return
        val owned = synchronized(lock) { byToken[claim.token] } ?: return
        releaseClaim(owned)
    }

    override fun release(jobID: String, epoch: Long) {
        val owned = synchronized(lock) { byJob[key(jobID, epoch)] } ?: return
        releaseClaim(owned)
    }

    override fun cancel(jobID: String, epoch: Long) {
        val owned = synchronized(lock) { byJob[key(jobID, epoch)] } ?: return
        if (removeClaim(owned)) {
            GenerationForegroundNative.cancel(
                owned.jobID, owned.epoch, owned.token)
            GenerationForegroundNative.release(
                owned.jobID, owned.epoch, owned.token)
        }
        stopServiceIfIdle(applicationContext)
        updateNotification(applicationContext)
    }

    override fun releaseAll(epoch: Long) {
        val owned = synchronized(lock) {
            byToken.values.filter { it.epoch == epoch }
        }
        for (claim in owned) {
            if (removeClaim(claim) && claim.registered) {
                GenerationForegroundNative.release(
                    claim.jobID, claim.epoch, claim.token)
            }
        }
        // Clear any native lease that lost its process-local claim record.
        GenerationForegroundNative.releaseAll(epoch)
        stopServiceIfIdle(applicationContext)
    }

    /** Root-stop/teardown safety: stop every claim without touching new work. */
    fun stopAll() {
        val owned = synchronized(lock) { byToken.values.toList() }
        for (claim in owned) {
            if (removeClaim(claim)) {
                GenerationForegroundNative.cancel(
                    claim.jobID, claim.epoch, claim.token)
                GenerationForegroundNative.release(
                    claim.jobID, claim.epoch, claim.token)
            }
        }
        stopServiceIfIdle(applicationContext)
    }

    fun confirmStart(token: String) {
        synchronized(lock) { byToken[token] }?.confirmed?.complete(true)
    }

    fun failStart(token: String, reason: String) {
        val claim = synchronized(lock) { byToken[token] } ?: return
        claim.confirmed.complete(false)
        removeClaim(claim)
        GenerationForegroundNative.deny(claim.jobID, claim.epoch, reason)
    }

    fun activeCount(): Int = synchronized(lock) { byToken.size }

    fun activeClaims(): List<GenerationForegroundClaim> =
        synchronized(lock) { byToken.values.map(::publicClaim) }

    /** System/user stop: no paid request continues without a real FGS owner. */
    fun onServiceDestroyed() {
        val owned = synchronized(lock) { byToken.values.toList() }
        for (claim in owned) {
            if (removeClaim(claim)) {
                GenerationForegroundNative.cancel(
                    claim.jobID, claim.epoch, claim.token)
                GenerationForegroundNative.release(
                    claim.jobID, claim.epoch, claim.token)
            }
        }
        updateNotification(applicationContext)
    }

    fun onSystemTimeout() {
        val owned = synchronized(lock) { byToken.values.toList() }
        for (claim in owned) {
            if (removeClaim(claim)) {
                GenerationForegroundNative.cancel(
                    claim.jobID, claim.epoch, claim.token)
                GenerationForegroundNative.release(
                    claim.jobID, claim.epoch, claim.token)
            }
        }
        updateNotification(applicationContext)
    }

    fun cancelAll() {
        val owned = synchronized(lock) { byToken.values.toList() }
        for (claim in owned) {
            if (removeClaim(claim)) {
                GenerationForegroundNative.cancel(
                    claim.jobID, claim.epoch, claim.token)
                GenerationForegroundNative.release(
                    claim.jobID, claim.epoch, claim.token)
            }
        }
        stopServiceIfIdle(applicationContext)
        updateNotification(applicationContext)
    }

    /**
     * Bounded notification pump. Returns true while claims remain. A missing
     * or malformed native snapshot means ownership is no longer provable, so
     * the exact claim is cancelled/released instead of showing a stale
     * "protected" notification.
     */
    suspend fun pump(): Boolean {
        val context = applicationContext ?: return false
        val snapshot = synchronized(lock) { byToken.values.toList() }
        if (snapshot.isEmpty()) {
            stopServiceIfIdle(context)
            return false
        }
        val now = SystemClock.elapsedRealtime()
        for (claim in snapshot) {
            // The service may confirm before the owner's native register call
            // completes; an unregistered claim is not yet proof. If it stays
            // unregistered past the bounded window (cancelled acquire, host
            // failure), release it so no idle FGS remains.
            if (!claim.registered) {
                if (now - claim.startedAt > 15_000L) {
                    expireClaim(claim, "foregroundRegistrationLost")
                }
                continue
            }
            if (now - claim.startedAt > MAX_DATA_SYNC_MILLIS) {
                expireClaim(claim, "timeout")
                continue
            }
            // One bounded native pump step: the native service reuses the
            // durable payload/task/backoff and ignores the call while a
            // worker is active or the next poll is not due. JNI calls can
            // touch the durable store, so they never run on the UI thread.
            val raw = withContext(Dispatchers.IO) {
                GenerationForegroundNative.poll(
                    claim.jobID, claim.epoch, claim.token)
                GenerationForegroundNative.snapshot(
                    claim.jobID, claim.epoch, claim.token)
            }
            val parsed = raw?.let(GenerationForegroundWire::parse) ?: run {
                expireClaim(claim, "foregroundLost")
                continue
            }
            claim.lastState = parsed.state
            claim.progress = parsed.progress
            if (parsed.terminal) {
                releaseClaim(claim)
            }
        }
        updateNotification(context)
        return synchronized(lock) { byToken.isNotEmpty() }
    }

    private fun expireClaim(claim: Claim, reason: String) {
        if (!removeClaim(claim)) return
        GenerationForegroundNative.cancel(claim.jobID, claim.epoch, claim.token)
        GenerationForegroundNative.release(claim.jobID, claim.epoch, claim.token)
    }

    private fun releaseClaim(claim: Claim) {
        if (!removeClaim(claim)) return
        if (claim.registered) {
            GenerationForegroundNative.release(
                claim.jobID, claim.epoch, claim.token)
        }
        stopServiceIfIdle(applicationContext)
    }

    private fun removeClaim(claim: Claim): Boolean = synchronized(lock) {
        val removed = byToken.remove(claim.token) != null
        byJob.remove(key(claim.jobID, claim.epoch))
        byReturnToken.remove(claim.returnToken)
        // The accepted context is intentionally NOT retained after the exact
        // claim leaves process ownership (terminal/root/expiration/denial).
        removed
    }

    // MARK: - Notification

    private fun notificationsUsable(context: Context): Boolean = runCatching {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            return false
        }
        if (Build.VERSION.SDK_INT >= 33) {
            return ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        }
        return true
    }.getOrDefault(false)

    private fun ensureChannel(context: Context): Boolean = runCatching {
        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return false
        val channel = NotificationChannel(
            CHANNEL_ID,
            copy("Media generation", "媒体生成"),
            NotificationManager.IMPORTANCE_LOW).apply {
            description = copy(
                "Shows active cloud media generation and its Cancel action.",
                "显示正在进行的云端媒体生成，并提供取消操作。")
            setShowBadge(false)
            setSound(null, null)
        }
        manager.createNotificationChannel(channel)
        return true
    }.getOrDefault(false)

    fun buildNotification(context: Context): Notification {
        val claims = activeClaims()
        val anyProgress = claims.mapNotNull { claimProgress(it.token) }
        val progress = if (anyProgress.size == claims.size && anyProgress.isNotEmpty()) {
            (anyProgress.average() * 100).toInt().coerceIn(0, 100)
        } else {
            null
        }
        val title = if (claims.size <= 1) {
            copy("Generating media", "正在生成媒体")
        } else {
            copy("Generating media (${claims.size})", "正在生成媒体（${claims.size}）")
        }
        val text = when {
            claims.isEmpty() -> copy("Finishing…", "正在结束…")
            claims.size == 1 -> claimText(claims.first().token)
            else -> copy("Tap to return to Floe", "点按返回 Floe")
        }
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (progress != null) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        val cancelIntent = Intent(context, GenerationForegroundCancelReceiver::class.java)
            .setAction(ACTION_CANCEL_ALL)
        builder.addAction(
            android.R.drawable.ic_menu_close_clear_cancel,
            copy("Cancel", "取消"),
            PendingIntent.getBroadcast(
                context, 0x46474E32, cancelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        val launch = context.packageManager.getLaunchIntentForPackage(
            context.packageName)
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (claims.size == 1) {
                // The content Intent carries ONLY this opaque return token and
                // a one-shot request id. It carries no project id, path or
                // root: the App re-resolves the registered live claim + exact
                // captured context + current native bound epoch on delivery.
                // A pre-lease claim, or one without the exact accepted context,
                // gets no return identity (the App never fabricates it).
                val returnToken = synchronized(lock) {
                    byToken[claims.first().token]
                        ?.takeIf { it.registered && it.returnContext != null }
                        ?.returnToken
                }
                if (returnToken != null) {
                    launch.action = GenerationReturnNavigation.ACTION_RETURN
                    launch.putExtra(
                        GenerationReturnNavigation.EXTRA_RETURN_TOKEN,
                        returnToken)
                    launch.putExtra(
                        GenerationReturnNavigation.EXTRA_RETURN_REQUEST_ID,
                        UUID.randomUUID().toString().lowercase())
                }
            }
            builder.setContentIntent(PendingIntent.getActivity(
                context, 0x46474E33, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        return builder.build()
    }

    fun updateNotification(context: Context?) {
        val app = context ?: return
        if (!isInitialized) return
        val manager = NotificationManagerCompat.from(app)
        if (activeCount() == 0) {
            manager.cancel(NOTIFICATION_ID)
            return
        }
        if (!notificationsUsable(app)) return
        try {
            manager.notify(NOTIFICATION_ID, buildNotification(app))
        } catch (_: SecurityException) {
            // The pump/native lease remains authoritative; the service stops
            // only through its bounded timeout/release path.
        }
    }

    private fun claimProgress(token: String): Double? =
        synchronized(lock) { byToken[token]?.progress }

    private fun claimText(token: String): String {
        val claim = synchronized(lock) { byToken[token] } ?: return ""
        val percent = claim.progress?.let { (it * 100).toInt().coerceIn(0, 100) }
        val state = claim.lastState
        if (percent != null) {
            return copy("Generating · $percent%", "正在生成 · $percent%")
        }
        return when (state) {
            "submitted", "preparing" -> copy("Waiting for provider", "等待服务商")
            "running" -> copy("Generating", "正在生成")
            "downloading", "completed" -> copy("Downloading result", "正在下载结果")
            else -> copy("Generating", "正在生成")
        }
    }

    private fun copy(english: String, chinese: String): String =
        if (Locale.getDefault().language == "zh") chinese else english

    private fun stopServiceIfIdle(context: Context?) {
        val app = context ?: return
        if (activeCount() != 0) return
        try {
            app.stopService(Intent(app, GenerationForegroundService::class.java))
        } catch (_: Throwable) {
        }
        updateNotification(app)
    }
}

/**
 * Strict parser for the bounded native snapshot ASCII. A malformed field is
 * `null` (unknown), never a fabricated zero/terminal.
 */
object GenerationForegroundWire {
    data class Snapshot(
        val state: String,
        val terminal: Boolean,
        val progress: Double?,
        val hasProviderTask: Boolean,
        val epoch: Long,
    )

    fun parse(raw: String): Snapshot? {
        if (raw.length > 256) return null
        val values = HashMap<String, String>()
        for (part in raw.split(';')) {
            val separator = part.indexOf('=')
            if (separator <= 0 || separator == part.lastIndex) return null
            val key = part.substring(0, separator)
            val value = part.substring(separator + 1)
            if (key !in setOf("state", "terminal", "progress", "task", "epoch")) {
                return null
            }
            if (values.put(key, value) != null) return null
        }
        val state = values["state"] ?: return null
        if (state.isEmpty() || state.length > 32 ||
            !state.all { it.isLetterOrDigit() || it == '.' || it == '_' || it == '-' }) {
            return null
        }
        val terminal = when (values["terminal"]) {
            "0" -> false
            "1" -> true
            else -> return null
        }
        val task = when (values["task"]) {
            "0" -> false
            "1" -> true
            else -> return null
        }
        val epoch = values["epoch"]?.toLongOrNull() ?: return null
        if (epoch <= 0L) return null
        val progress = when (val rawProgress = values["progress"]) {
            null -> return null
            "-1" -> null
            else -> rawProgress.toDoubleOrNull()?.takeIf {
                it.isFinite() && it in 0.0..1.0
            } ?: return null
        }
        return Snapshot(state, terminal, progress, task, epoch)
    }
}
