// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID

/**
 * Process-local, revocable controls plus a compact truthful status line.
 *
 * The status is presentation only. It is fed from the real claimed platform
 * tool lifecycle (started -> actual outcome) and from the typed background
 * document-view verification. It never carries node text, typed values,
 * credentials, a fake click trail or a claim that an accepted launch was
 * rendered. Only the latest operation is retained (bounded fields, no event
 * list), and every update is fenced by the exact owner/token and cleared when
 * the owner ends or the user pauses/stops.
 *
 * Notifications and overlays cannot revive a past run: [clear] removes both,
 * and a stale receiver token is ignored.
 */
internal class PhoneAutomationControls(
    private val context: Context,
    private val act: (PhoneControlOwner, Action) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val windows = context.getSystemService(WindowManager::class.java)
    private var owner: PhoneControlOwner? = null
    private var token = UUID.randomUUID().toString()
    enum class Action { PAUSE, RESUME, TAKE_OVER }

    private var overlay: LinearLayout? = null
    private var overlayTitle: TextView? = null
    private var overlayStatus: TextView? = null
    private var paused = false
    private var title = ""
    private var showOverlay = false
    private var operation: PhoneAutomationOperation? = null
    private var operationOwner: PhoneControlOwner? = null
    /** A start that arrived before [show] bound the same owner. RAM-only and
     * replaced by the next start/finish; never a history buffer. */
    private var pendingOperation: Pair<PhoneControlOwner, String>? = null

    fun show(owner: PhoneControlOwner, title: String, overlay: Boolean, paused: Boolean = false) {
        main.post {
            if (this.owner != owner && operationOwner != owner) {
                this.operation = null
                this.operationOwner = null
            }
            if (this.paused != paused) {
                this.operation = null
                this.operationOwner = null
            }
            if (this.owner != owner || this.paused != paused) {
                removeOverlay()
                token = UUID.randomUUID().toString()
            }
            this.owner = owner
            this.paused = paused
            this.title = PhoneAutomationStatusText.bounded(title, 48)
            showOverlay = overlay
            // The trusted pump calls start immediately before the first
            // device call, while the owner may not have been rendered yet.
            // Adopt that bounded start once it belongs to this exact owner.
            if (!paused) {
                pendingOperation?.takeIf { it.first == owner }?.let { (_, label) ->
                    operation = PhoneAutomationStatusText.operation(
                        label, PhoneAutomationOperationState.RUNNING)
                    operationOwner = owner
                    pendingOperation = null
                }
            } else {
                pendingOperation = null
            }
            PhoneAutomationRelay.controls = this
            render()
        }
    }

    /** A real claimed device operation started. UI-only; no authority. */
    fun operationStarted(owner: PhoneControlOwner, label: String) {
        main.post {
            if (paused) return@post
            if (this.owner == null) {
                pendingOperation = owner to PhoneAutomationStatusText.bounded(label, 32)
                return@post
            }
            if (this.owner != owner) return@post
            operation = PhoneAutomationStatusText.operation(
                label, PhoneAutomationOperationState.RUNNING)
            operationOwner = owner
            render()
        }
    }

    /** The actual settled outcome (or an honest unknown/cancel). */
    fun operationFinished(
        owner: PhoneControlOwner,
        label: String,
        state: PhoneAutomationOperationState,
        note: String? = null,
    ) {
        main.post {
            if (this.owner == null) {
                if (pendingOperation?.first == owner) pendingOperation = null
                operation = PhoneAutomationStatusText.operation(
                    label,
                    if (paused) PhoneAutomationOperationState.CANCELLED else state,
                    note,
                )
                operationOwner = owner
                return@post
            }
            if (this.owner != owner) return@post
            operation = PhoneAutomationStatusText.operation(
                label,
                if (paused) PhoneAutomationOperationState.CANCELLED else state,
                note,
            )
            operationOwner = owner
            render()
        }
    }

    internal fun receive(receivedToken: String?, action: String?) {
        main.post {
            if (owner == null || token != receivedToken) return@post
            val current = owner ?: return@post
            val accepted = when (action) {
                "pause" -> if (!paused) Action.PAUSE else return@post
                "resume" -> if (paused) Action.RESUME else return@post
                "stop" -> Action.TAKE_OVER
                else -> return@post
            }
            act(current, accepted)
        }
    }

    private fun statusLine(): String {
        if (paused) return context.getString(R.string.phone_automation_paused)
        val current = operation
            ?: return context.getString(R.string.device_automation_status_active)
        val state = when (current.state) {
            PhoneAutomationOperationState.RUNNING -> R.string.device_automation_state_running
            PhoneAutomationOperationState.DONE -> R.string.device_automation_state_done
            PhoneAutomationOperationState.WAITING -> R.string.device_automation_state_waiting
            PhoneAutomationOperationState.FAILED -> R.string.device_automation_state_failed
            PhoneAutomationOperationState.UNKNOWN -> R.string.device_automation_state_unknown
            PhoneAutomationOperationState.CANCELLED -> R.string.device_automation_state_cancelled
        }
        val stateText = context.getString(state)
        return if (current.note == null) {
            context.getString(R.string.device_automation_status_format,
                current.label, stateText)
        } else {
            context.getString(R.string.device_automation_status_note_format,
                current.label, stateText, current.note.orEmpty())
        }
    }

    private fun render() {
        if (owner == null) return
        runCatching {
            notifications.createNotificationChannel(NotificationChannel(CHANNEL,
                context.getString(R.string.phone_automation_title), NotificationManager.IMPORTANCE_DEFAULT))
            val current = owner ?: return
            val launch = PendingIntent.getActivity(context, 9481,
                Intent(context, MainActivity::class.java)
                    .setAction(Intent.ACTION_VIEW)
                    .setData(Uri.parse("floe://task/${current.taskID}")),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            fun action(name: String, request: Int) = PendingIntent.getBroadcast(context, request,
                Intent(context, PhoneAutomationReceiver::class.java).setData(Uri.parse("floe-control://$token/$name"))
                    .putExtra("token", token).putExtra("action", name),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val status = statusLine()
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(context.getString(R.string.phone_automation_title))
                .setContentText(status.replace('\n', ' ')).setContentIntent(launch).setOngoing(true).setOnlyAlertOnce(true)
                .setSubText(title.takeIf { it.isNotBlank() })
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .addAction(0, context.getString(if (paused) R.string.phone_automation_resume else R.string.phone_automation_pause),
                    action(if (paused) "resume" else "pause", if (paused) 9484 else 9483))
                .addAction(0, context.getString(R.string.phone_automation_stop), action("stop", 9482))
            notifications.notify(NOTIFICATION, builder.build())
        }
        if (showOverlay && Settings.canDrawOverlays(context) && overlay == null) {
            runCatching {
                val capturedToken = token
                val capturedTitle = TextView(context).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                }
                val capturedStatus = TextView(context).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    maxLines = 2
                    ellipsize = android.text.TextUtils.TruncateAt.END
                }
                val container = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(10), dp(8), dp(10), dp(8))
                    background = GradientDrawable().apply {
                        setColor(0xE6202124.toInt())
                        cornerRadius = dp(10).toFloat()
                    }
                    fun control(label: Int, action: String) = Button(context).apply {
                        text = context.getString(label)
                        contentDescription = text
                        setOnClickListener {
                            receive(capturedToken, action)
                        }
                    }
                    addView(capturedTitle)
                    addView(capturedStatus)
                    addView(control(if (paused) R.string.phone_automation_resume else R.string.phone_automation_pause,
                        if (paused) "resume" else "pause"))
                    addView(control(R.string.phone_automation_stop, "stop"))
                }
                windows.addView(container, WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                    PixelFormat.TRANSLUCENT).apply { gravity = Gravity.END or Gravity.CENTER_VERTICAL })
                overlay = container
                overlayTitle = capturedTitle
                overlayStatus = capturedStatus
            }
        } else if (!showOverlay || !Settings.canDrawOverlays(context)) {
            removeOverlay()
        }
        overlayTitle?.text = title
        overlayStatus?.text = statusLine()
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(),
            context.resources.displayMetrics).toInt()

    private fun removeOverlay() {
        overlay?.let { runCatching { windows.removeView(it) } }
        overlay = null
        overlayTitle = null
        overlayStatus = null
    }

    fun clear(expectedOwner: PhoneControlOwner? = null) {
        main.post {
            if (expectedOwner != null && owner != expectedOwner) return@post
            owner = null
            token = UUID.randomUUID().toString()
            operation = null
            operationOwner = null
            pendingOperation = null
            removeOverlay()
            notifications.cancel(NOTIFICATION)
            if (PhoneAutomationRelay.controls === this) PhoneAutomationRelay.controls = null
        }
    }

    companion object {
        private const val CHANNEL = "phone_automation"
        private const val NOTIFICATION = 9480
    }
}

internal object PhoneAutomationRelay {
    @Volatile var controls: PhoneAutomationControls? = null
}

class PhoneAutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PhoneAutomationRelay.controls?.receive(intent.getStringExtra("token"), intent.getStringExtra("action"))
    }
}
