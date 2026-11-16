// SPDX-License-Identifier: MPL-2.0
//
// PRIVATE user-question notification bridge.
//
// The notification never contains the question text, options, a task title or
// any answer content: it is a private reminder to open Floe. A notification
// text reply is available ONLY for a text-only question and is submitted
// through the SAME exact-once native answer command (request digest + answer
// nonce + expected revision + session epoch). If the App/runtime is not alive
// when the reply arrives, the receiver does not fabricate a settlement; it
// posts a neutral "open Floe" reminder instead.
//
// Notifications are used only when the user has already allowed them; the
// in-app sheet is fully functional without POST_NOTIFICATIONS. Temporary
// questions are never notified.
//
// The same post path is used by the durable App-owned attention signal when
// no visible holder owns the conversation. The reply action is attached ONLY
// while an exact live holder session exists; a background identifier-only
// reminder still opens the task and re-reads the authoritative question.
package com.floe.android.host.questions

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.floe.android.MainActivity
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.host.entryflow.C07EntryNotification
import com.floe.android.feature.conversation.UserQuestionAnswerRequestUi
import com.floe.android.feature.conversation.UserQuestionSnapshotUi
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

internal object UserQuestionNotifications {
    const val CHANNEL_ID = "floe.questions.v1"
    const val EXTRA_CONVERSATION_ID = "floe.question.conversationID"
    const val EXTRA_SESSION_EPOCH = "floe.question.sessionEpoch"
    const val EXTRA_REQUEST_ID = "floe.question.requestID"
    const val EXTRA_REQUEST_DIGEST = "floe.question.requestDigest"
    const val EXTRA_QUESTION_ID = "floe.question.questionID"
    const val EXTRA_RUN_ID = "floe.question.runID"
    const val EXTRA_REVISION = "floe.question.revision"
    const val EXTRA_NONCE = "floe.question.answerNonce"
    const val REPLY_KEY = "floe.question.reply"
    private const val NOTIFICATION_ID_BASE = 81_000

    private val controller = AtomicReference<UserQuestionHostController?>()

    /** The ONE notification posted per conversation, with its exact durable
     * identity. A late/null refresh may withdraw only this identity; it can
     * never cancel a newer question's reminder in the same conversation. */
    private data class PostedQuestion(
        val requestId: String,
        val questionId: String,
        val runId: String,
    )

    private val posted = ConcurrentHashMap<String, PostedQuestion>()

    fun install(controller: UserQuestionHostController) {
        this.controller.set(controller)
    }

    /**
     * Visible-holder path. Returns true only when a real reminder was posted.
     * An empty/settled snapshot withdraws the conversation's tracked notice.
     */
    fun onSnapshot(
        context: Context,
        session: ConversationSessionToken,
        snapshot: UserQuestionSnapshotUi?,
    ): Boolean {
        if (snapshot == null || !snapshot.hasPending || snapshot.isEphemeral ||
            !sameUuid(snapshot.conversationId, session.conversationId)
        ) {
            return cancel(context, session.conversationId)
        }
        return postQuestion(context, session.conversationId, snapshot, session)
    }

    /**
     * Durable App-owned path. [replySession] may be null when no visible
     * holder currently owns the conversation: the reminder remains truthful
     * (identifier-only open) and never offers a reply that cannot be
     * revalidated by the exact holder/session gate.
     */
    fun postQuestion(
        context: Context,
        conversationId: String,
        snapshot: UserQuestionSnapshotUi,
        replySession: ConversationSessionToken?,
    ): Boolean {
        val conversation = canonicalUuid(conversationId) ?: return false
        if (snapshot.isEphemeral || !snapshot.hasPending ||
            !sameUuid(snapshot.conversationId, conversation)
        ) return false
        val question = snapshot.currentQuestion ?: return false
        if (!question.isPending) return false
        val runId = canonicalUuid(question.runId) ?: return false
        if (snapshot.requestId.isEmpty() || snapshot.requestId.length > 160 ||
            question.questionId.length > 200 ||
            !question.questionId.startsWith(snapshot.requestId + ".") ||
            snapshot.requestDigest.length != 64 ||
            question.answerNonce.isEmpty()
        ) return false
        if (!notificationsAllowed(context)) return false
        return UserQuestionNoticeSerial.run {
            ensureChannel(context)
            // C07 identifier-only return: the content tap opens the EXACT durable
            // conversation so the existing question surface re-reads the live
            // pending state. No question text/answer is placed in the Intent and
            // no answer is submitted by tapping. The question's own run id rides
            // as a second validated identifier (N03): the entry host re-proves
            // membership before the conversation presents that recorded run.
            val launch = Intent(context, MainActivity::class.java)
                .setAction(C07EntryNotification.ACTION_QUESTION)
                .setData(Uri.Builder().scheme("floe-question").authority("open").appendPath(conversation).build())
                .setPackage(context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(C07EntryNotification.EXTRA_CONVERSATION_ID, conversationId)
                .putExtra(C07EntryNotification.EXTRA_REQUEST_ID, snapshot.requestId)
                .putExtra(C07EntryNotification.EXTRA_QUESTION_ID, question.questionId)
                .putExtra(C07EntryNotification.EXTRA_RUN_ID, runId)
            val contentIntent = PendingIntent.getActivity(
                context,
                notificationId(conversation),
                launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(if (chinese()) "Floe 需要你的输入" else "Floe needs your input")
                .setContentText(if (chinese()) "打开 Floe 回答问题" else "Open Floe to answer")
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setPublicVersion(
                    NotificationCompat.Builder(context, CHANNEL_ID)
                        .setSmallIcon(context.applicationInfo.icon)
                        .setContentTitle(if (chinese()) "Floe 等待输入" else "Floe is waiting")
                        .setContentText(if (chinese()) "打开 Floe 继续" else "Open Floe to continue")
                        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                        .build(),
                )
            contentIntent?.let(builder::setContentIntent)
            val exactReplySession = replySession?.takeIf {
                it.sessionEpoch >= 0 && sameUuid(it.conversationId, conversation)
            }
            if (question.isTextOnly && exactReplySession != null) {
                val replyIntent = Intent(context, UserQuestionReplyReceiver::class.java).apply {
                    data = Uri.Builder().scheme("floe-question").authority("reply").appendPath(conversation).build()
                    // Preserve the EXACT holder spelling: submitReply rebuilds the
                    // session token and the live-owner gate compares it verbatim.
                    putExtra(EXTRA_CONVERSATION_ID, exactReplySession.conversationId)
                    putExtra(EXTRA_SESSION_EPOCH, exactReplySession.sessionEpoch)
                    putExtra(EXTRA_REQUEST_ID, snapshot.requestId)
                    putExtra(EXTRA_REQUEST_DIGEST, snapshot.requestDigest)
                    putExtra(EXTRA_QUESTION_ID, question.questionId)
                    putExtra(EXTRA_RUN_ID, runId)
                    putExtra(EXTRA_REVISION, question.revision)
                    putExtra(EXTRA_NONCE, question.answerNonce)
                }
                val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
                val replyPending = PendingIntent.getBroadcast(
                    context,
                    notificationId(conversation),
                    replyIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
                )
                val remoteInput = RemoteInput.Builder(REPLY_KEY)
                    .setLabel(if (chinese()) "输入回答" else "Type answer")
                    .build()
                builder.addAction(
                    NotificationCompat.Action.Builder(
                        0,
                        if (chinese()) "回复" else "Reply",
                        replyPending,
                    ).addRemoteInput(remoteInput).build(),
                )
            }
            try {
                val manager = NotificationManagerCompat.from(context)
                // Remove this conversation's pre-tag legacy notice on upgrade.
                manager.cancel(notificationId(conversation))
                manager.notify(conversation, NOTIFICATION_ID_BASE, builder.build())
                posted[conversation] = PostedQuestion(
                    requestId = snapshot.requestId,
                    questionId = question.questionId,
                    runId = runId,
                )
                true
            } catch (_: SecurityException) {
                false
            } catch (_: IllegalArgumentException) {
                false
            }
        }
    }

    /** Exact identity of the currently posted reminder, if this process
     * posted one. Null after a restart (the OS notice may still exist); the
     * attention signal then uses [postedRequestId] plus an authoritative
     * empty read to withdraw it. */
    fun postedRequestId(conversationId: String): String? {
        val conversation = canonicalUuid(conversationId) ?: return null
        return UserQuestionNoticeSerial.run { posted[conversation]?.requestId }
    }

    /** Withdraw only the exact question reminder that was posted. A newer
     * question in the same conversation is never cancelled by a stale
     * settlement/withdrawal callback. */
    fun cancelIfCurrent(
        context: Context,
        conversationId: String,
        requestId: String,
        questionId: String,
    ): Boolean {
        val conversation = canonicalUuid(conversationId) ?: return false
        return UserQuestionNoticeSerial.run {
            val current = posted[conversation] ?: return@run false
            if (current.requestId != requestId || current.questionId != questionId) {
                return@run false
            }
            NotificationManagerCompat.from(context).cancel(conversation, NOTIFICATION_ID_BASE)
            posted.remove(conversation, current)
            true
        }
    }

    fun cancel(context: Context, conversationId: String): Boolean {
        val conversation = canonicalUuid(conversationId) ?: return false
        return UserQuestionNoticeSerial.run {
            val manager = NotificationManagerCompat.from(context)
            manager.cancel(conversation, NOTIFICATION_ID_BASE)
            manager.cancel(notificationId(conversation)) // Pre-tag legacy notice.
            posted.remove(conversation)
            true
        }
    }

    /** Retire a notice from an earlier process only if no newer local post won. */
    fun cancelIfUntracked(context: Context, conversationId: String): Boolean {
        val conversation = canonicalUuid(conversationId) ?: return false
        return UserQuestionNoticeSerial.run {
            if (posted.containsKey(conversation)) return@run false
            val manager = NotificationManagerCompat.from(context)
            manager.cancel(conversation, NOTIFICATION_ID_BASE)
            manager.cancel(notificationId(conversation))
            true
        }
    }

    /** Broadcast receiver entry. Returns true only when a live controller was
     * asked to settle; the native receipt still decides the real outcome. */
    fun submitReply(context: Context, intent: Intent): Boolean {
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(REPLY_KEY)?.toString()?.trim().orEmpty()
        if (text.isEmpty()) return false
        val conversationId = intent.getStringExtra(EXTRA_CONVERSATION_ID) ?: return false
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return false
        val requestDigest = intent.getStringExtra(EXTRA_REQUEST_DIGEST) ?: return false
        val questionId = intent.getStringExtra(EXTRA_QUESTION_ID) ?: return false
        val runId = intent.getStringExtra(EXTRA_RUN_ID) ?: return false
        val nonce = intent.getStringExtra(EXTRA_NONCE) ?: return false
        val revision = intent.getIntExtra(EXTRA_REVISION, -1)
        val epoch = intent.getLongExtra(EXTRA_SESSION_EPOCH, -1L)
        if (revision < 1 || epoch < 0) return false
        val live = controller.get() ?: return false
        val session = ConversationSessionToken(conversationId, epoch)
        val request = UserQuestionAnswerRequestUi(
            requestId = requestId,
            requestDigest = requestDigest,
            questionId = questionId,
            runId = runId,
            expectedRevision = revision,
            answerNonce = nonce,
            selectedOptionIds = emptyList(),
            freeText = text.take(1_000),
        )
        if (!live.answer(session, request)) return false
        cancelIfCurrent(context, conversationId, requestId, questionId)
        return true
    }

    fun notificationsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) return false
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    if (chinese()) "任务提问" else "Task questions",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = if (chinese()) {
                        "任务需要你回答时提醒你打开 Floe"
                    } else {
                        "Reminds you to open Floe when a task needs your answer"
                    }
                    setSound(null, null)
                    enableVibration(false)
                    lockscreenVisibility = android.app.Notification.VISIBILITY_PRIVATE
                },
            )
        }
    }

    private fun notificationId(conversationId: String): Int =
        NOTIFICATION_ID_BASE + (conversationId.hashCode() and 0x0FFF)

    private fun canonicalUuid(raw: String): String? =
        runCatching { UUID.fromString(raw).toString() }.getOrNull()

    private fun sameUuid(left: String, right: String): Boolean =
        runCatching { UUID.fromString(left) == UUID.fromString(right) }.getOrDefault(false)

    private fun chinese(): Boolean =
        Locale.getDefault().language.startsWith("zh", ignoreCase = true)
}

/** Exported=false; reached only by the explicit PendingIntent above. */
class UserQuestionReplyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        val accepted = UserQuestionNotifications.submitReply(context, intent)
        if (!accepted) {
            // No live runtime/session: never pretend the answer settled. The
            // App will recover the durable question and show it in-app.
            UserQuestionNotifications.ensureChannel(context)
            UserQuestionNotificationsFallback.notify(context)
        }
        pending.finish()
    }
}

internal object UserQuestionNotificationsFallback {
    private const val ID = 81_999

    fun notify(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP) }
            ?: return
        val intent = PendingIntent.getActivity(
            context, ID, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(
            context, UserQuestionNotifications.CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Floe")
            .setContentText("Open Floe to answer")
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setAutoCancel(true)
            .setContentIntent(intent)
            .build()
        if (NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            try {
                NotificationManagerCompat.from(context).notify(ID, notification)
            } catch (_: SecurityException) {
                // Permission changed after the check: no false settlement.
            }
        }
    }
}
