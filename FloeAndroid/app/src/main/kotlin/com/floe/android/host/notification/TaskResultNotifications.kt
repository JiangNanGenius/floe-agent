// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.notification

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.host.entryflow.C07EntryNotification
import java.util.UUID

/** The distinct durable outcomes a result notice may present. Suspension is
 * NOT failure; a cancelled run is NOT a failure either. */
internal enum class RunTerminalNoticeKind { COMPLETED, FAILED, CANCELLED, SUSPENDED, WAITING }

/**
 * Pure policy for whole-task result notices. The caller supplies only the
 * NATIVE durable facts (`durableTerminal`, typed disposition, live owner) —
 * never a transient provider/tool error row. A live owner always wins.
 */
internal object RunTerminalNoticePolicy {
    private val KNOWN_POLICIES = setOf("off", "terminal", "critical", "stages")

    fun kindFor(
        durableState: String,
        dispositionRaw: String?,
        durableTerminal: Boolean?,
        liveOwner: Boolean,
    ): RunTerminalNoticeKind? {
        if (liveOwner) {
            // A live parked approval is action-required, never a failure and
            // never the end of the run. Other live/retrying states stay
            // silent so a transient error cannot announce a terminal result.
            return if (durableState == "waitingApproval" || durableState == "paused") {
                RunTerminalNoticeKind.WAITING
            } else {
                null
            }
        }
        // The typed native member is authoritative; an older page falls back
        // to the exact durable state vocabulary, never to a UI state name.
        val disposition = dispositionRaw ?: when (durableState) {
            "completed" -> "completed"
            "failed" -> "failed"
            "cancelled" -> "cancelled"
            "checkpointed", "interrupted" -> "suspended"
            else -> "none"
        }
        if (durableTerminal == false) return null
        return when (disposition) {
            "completed" -> RunTerminalNoticeKind.COMPLETED
            "failed" -> RunTerminalNoticeKind.FAILED
            "cancelled" -> RunTerminalNoticeKind.CANCELLED
            "suspended" -> RunTerminalNoticeKind.SUSPENDED
            else -> null
        }
    }

    /** ⇄ TaskNotificationPolicy.shouldNotifyTerminal / Cancellation. An
     * absent policy keeps the historical `.stages` default; an unknown raw
     * value is corrupt and stays silent rather than guessing. */
    fun policyAllows(policyRaw: String?, kind: RunTerminalNoticeKind): Boolean {
        val policy = when {
            policyRaw == null -> "stages"
            policyRaw !in KNOWN_POLICIES -> return false
            else -> policyRaw
        }
        return when (kind) {
            RunTerminalNoticeKind.COMPLETED, RunTerminalNoticeKind.SUSPENDED ->
                policy == "terminal" || policy == "stages"
            RunTerminalNoticeKind.FAILED ->
                policy == "terminal" || policy == "critical" || policy == "stages"
            RunTerminalNoticeKind.CANCELLED ->
                policy == "terminal" || policy == "stages"
            RunTerminalNoticeKind.WAITING ->
                policy == "critical" || policy == "stages"
        }
    }

    fun shouldPost(
        kind: RunTerminalNoticeKind,
        policyRaw: String?,
        appIsForeground: Boolean,
    ): Boolean = !appIsForeground && policyAllows(policyRaw, kind)
}

/**
 * Exact-delivery fence for one live run's terminal notice. The host arms the
 * run when it really opens that stream incarnation; an async read may
 * consume the arm only while the SAME generation is still current. A retry,
 * replacement or retirement discards the arm, so a late old callback can
 * neither publish nor withdraw a newer activation's notice.
 */
internal class RunTerminalDeliveryFence {
    private val armed = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val waitingNotices = java.util.concurrent.ConcurrentHashMap<String, Boolean>()

    private fun key(conversationID: String, runID: String) = "$conversationID/$runID"

    fun arm(conversationID: String, runID: String, generation: Long) {
        armed[key(conversationID, runID)] = generation
    }

    fun isArmed(conversationID: String, runID: String, generation: Long): Boolean =
        armed[key(conversationID, runID)] == generation

    fun markWaitingNotice(conversationID: String, runID: String) {
        waitingNotices[key(conversationID, runID)] = true
    }

    fun hasWaitingNotice(conversationID: String, runID: String): Boolean =
        waitingNotices.containsKey(key(conversationID, runID))

    /** True only when THIS activation really posted an action-required
     * notice; the active resume then performs one cancel instead of a binder
     * call on every live snapshot. */
    fun consumeWaitingNotice(conversationID: String, runID: String): Boolean =
        waitingNotices.remove(key(conversationID, runID)) != null

    fun discard(conversationID: String, runID: String, generation: Long? = null) {
        val key = key(conversationID, runID)
        if (generation == null) armed.remove(key)
        else armed.remove(key, generation)
        waitingNotices.remove(key)
    }

    fun discardConversation(conversationID: String) {
        val prefix = "$conversationID/"
        for (key in armed.keys.toList()) {
            if (key.startsWith(prefix)) armed.remove(key)
        }
        for (key in waitingNotices.keys.toList()) {
            if (key.startsWith(prefix)) waitingNotices.remove(key)
        }
    }
}

/**
 * Whole-task result notifications over the EXISTING Android notification
 * system. This is not a second scheduler/owner: the run/foreground service
 * remains the liveness authority, and this object only presents one durable
 * terminal fact (or withdraws it) after the host has re-proven it.
 *
 * The content intent reuses the existing validated identifier-only task
 * entry (`ACTION_QUESTION` carries a canonical conversation id + optional
 * exact run id; no question text or answer). Tapping only re-reads and opens
 * the recorded task/run; it never starts, retries or answers anything.
 */
internal object TaskResultNotifications {
    const val CHANNEL_ID = "floe.task_results.v1"
    private const val RESULT_REQUEST_PREFIX = "task-result-"
    private const val RESULT_QUESTION_ID = "task-result"

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.n113_task_result_channel),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.n113_task_result_channel_description)
                setShowBadge(true)
            },
        )
    }

    fun post(
        context: Context,
        conversationID: String,
        runID: String,
        kind: RunTerminalNoticeKind,
        taskTitle: String?,
    ) {
        val conversation = canonicalUuid(conversationID) ?: return
        val run = canonicalUuid(runID) ?: return
        ensureChannel(context)
        if (!notificationsAllowed(context)) return
        val title = taskTitle
            ?.replace('\n', ' ')?.trim()?.takeIf { it.isNotEmpty() }
            ?: context.getString(R.string.n113_task_result_title_fallback)
        val body = when (kind) {
            RunTerminalNoticeKind.COMPLETED -> context.getString(R.string.n113_task_result_completed)
            RunTerminalNoticeKind.FAILED -> context.getString(R.string.n113_task_result_failed)
            RunTerminalNoticeKind.CANCELLED -> context.getString(R.string.n113_task_result_cancelled)
            RunTerminalNoticeKind.SUSPENDED -> context.getString(R.string.n113_task_result_suspended)
            RunTerminalNoticeKind.WAITING -> context.getString(R.string.n113_task_result_waiting)
        }
        val launch = Intent(context, MainActivity::class.java)
            .setAction(C07EntryNotification.ACTION_QUESTION)
            .setPackage(context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(C07EntryNotification.EXTRA_CONVERSATION_ID, conversation)
            .putExtra(
                C07EntryNotification.EXTRA_REQUEST_ID,
                RESULT_REQUEST_PREFIX + kind.name.lowercase() + "-" + run,
            )
            .putExtra(C07EntryNotification.EXTRA_QUESTION_ID, RESULT_QUESTION_ID)
            .putExtra(C07EntryNotification.EXTRA_RUN_ID, run)
        val contentIntent = PendingIntent.getActivity(
            context,
            notificationID(run),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val publicVersion = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(context.getString(R.string.n113_task_result_title_fallback))
            .setContentText(body)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title.take(80))
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(
                when (kind) {
                    RunTerminalNoticeKind.FAILED -> NotificationCompat.CATEGORY_ERROR
                    RunTerminalNoticeKind.WAITING -> NotificationCompat.CATEGORY_REMINDER
                    else -> NotificationCompat.CATEGORY_STATUS
                },
            )
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(
                if (kind == RunTerminalNoticeKind.FAILED ||
                    kind == RunTerminalNoticeKind.WAITING
                ) {
                    NotificationCompat.PRIORITY_DEFAULT
                } else {
                    NotificationCompat.PRIORITY_LOW
                },
            )
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setPublicVersion(publicVersion)
            .setContentIntent(contentIntent)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(notificationID(run), notification)
        } catch (_: SecurityException) {
            // Permission changed after the check: the in-app task remains
            // the visible truth and nothing is claimed.
        }
    }

    fun cancel(context: Context, runID: String) {
        val run = canonicalUuid(runID) ?: return
        NotificationManagerCompat.from(context).cancel(notificationID(run))
    }

    /** App is visible: the thread/surface itself shows the terminal state, so
     * a system alert would duplicate it. Foreground-service importance is NOT
     * foreground activity importance. */
    fun appIsForeground(context: Context): Boolean {
        val manager = context.getSystemService(ActivityManager::class.java) ?: return false
        val states = manager.runningAppProcesses ?: return false
        return states.any { state ->
            state.processName == context.packageName &&
                state.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }
    }

    private fun notificationsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    private fun notificationID(runID: String): Int =
        900_000 + (runID.hashCode() and 0x3FFFF)

    private fun canonicalUuid(raw: String): String? =
        runCatching { UUID.fromString(raw).toString() }.getOrNull()
}
