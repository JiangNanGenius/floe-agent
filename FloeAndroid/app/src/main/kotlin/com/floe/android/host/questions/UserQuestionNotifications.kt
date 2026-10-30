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
package com.floe.android.host.questions

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import com.floe.android.feature.conversation.ConversationSessionToken
import com.floe.android.feature.conversation.UserQuestionAnswerRequestUi
import com.floe.android.feature.conversation.UserQuestionSnapshotUi
import java.util.Locale
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

    fun install(controller: UserQuestionHostController) {
        this.controller.set(controller)
    }

    fun onSnapshot(
        context: Context,
        session: ConversationSessionToken,
        snapshot: UserQuestionSnapshotUi?,
    ) {
        val question = snapshot?.currentQuestion
        if (snapshot == null || question == null || !question.isPending ||
            snapshot.isEphemeral || snapshot.conversationId != session.conversationId
        ) {
            cancel(context, session.conversationId)
            return
        }
        if (!notificationsAllowed(context)) return
        ensureChannel(context)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP) }
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                context,
                notificationId(session.conversationId),
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
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
        if (question.isTextOnly) {
            val replyIntent = Intent(context, UserQuestionReplyReceiver::class.java).apply {
                putExtra(EXTRA_CONVERSATION_ID, session.conversationId)
                putExtra(EXTRA_SESSION_EPOCH, session.sessionEpoch)
                putExtra(EXTRA_REQUEST_ID, question.requestId)
                putExtra(EXTRA_REQUEST_DIGEST, question.requestDigest)
                putExtra(EXTRA_QUESTION_ID, question.questionId)
                putExtra(EXTRA_RUN_ID, question.runId)
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
                notificationId(session.conversationId),
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
        NotificationManagerCompat.from(context).notify(
            notificationId(session.conversationId), builder.build())
    }

    fun cancel(context: Context, conversationId: String) {
        NotificationManagerCompat.from(context).cancel(notificationId(conversationId))
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
        cancel(context, conversationId)
        return true
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

    private fun notificationsAllowed(context: Context): Boolean =
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    private fun notificationId(conversationId: String): Int =
        NOTIFICATION_ID_BASE + (conversationId.hashCode() and 0x0FFF)

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
            NotificationManagerCompat.from(context).notify(ID, notification)
        }
    }
}
