// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import androidx.core.app.NotificationCompat
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID

/** Process-local, revocable controls. Notifications cannot revive a past run. */
internal class PhoneAutomationControls(private val context: Context, private val act: (PhoneControlOwner, Action) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val windows = context.getSystemService(WindowManager::class.java)
    private var owner: PhoneControlOwner? = null
    private var token = UUID.randomUUID().toString()
    enum class Action { PAUSE, RESUME, TAKE_OVER }
    private var overlay: LinearLayout? = null
    private var paused = false
    private var title = ""
    private var showOverlay = false

    fun show(owner: PhoneControlOwner, title: String, overlay: Boolean, paused: Boolean = false) { main.post {
        if (this.owner != owner || this.paused != paused) {
            removeOverlay()
            token = UUID.randomUUID().toString()
        }
        this.owner = owner
        this.paused = paused
        this.title = title
        showOverlay = overlay
        PhoneAutomationRelay.controls = this
        render()
    } }

    internal fun receive(receivedToken: String?, action: String?) { main.post {
        if (owner == null || token != receivedToken) return@post
        val current = owner ?: return@post
        val accepted = when (action) {
            "pause" -> if (!paused) Action.PAUSE else return@post
            "resume" -> if (paused) Action.RESUME else return@post
            "stop" -> Action.TAKE_OVER
            else -> return@post
        }
        act(current, accepted)
    } }


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
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(context.getString(R.string.phone_automation_title))
                .setContentText(if (paused) context.getString(R.string.phone_automation_paused) else title).setContentIntent(launch).setOngoing(true).setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .addAction(0, context.getString(if (paused) R.string.phone_automation_resume else R.string.phone_automation_pause),
                    action(if (paused) "resume" else "pause", if (paused) 9484 else 9483))
                .addAction(0, context.getString(R.string.phone_automation_stop), action("stop", 9482))
            notifications.notify(NOTIFICATION, builder.build())
        }
        if (showOverlay && Settings.canDrawOverlays(context) && overlay == null) {
            runCatching {
                val capturedToken = token
                val button = LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    fun control(label: Int, action: String) = Button(context).apply {
                        text = context.getString(label)
                        contentDescription = text
                        setOnClickListener { receive(capturedToken, action) }
                    }
                    addView(control(if (paused) R.string.phone_automation_resume else R.string.phone_automation_pause,
                        if (paused) "resume" else "pause"))
                    addView(control(R.string.phone_automation_stop, "stop"))
                }
                windows.addView(button, WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                    PixelFormat.TRANSLUCENT).apply { gravity = Gravity.END or Gravity.CENTER_VERTICAL })
                overlay = button
            }
        } else if (!showOverlay || !Settings.canDrawOverlays(context)) removeOverlay()
    }

    private fun removeOverlay() {
        overlay?.let { runCatching { windows.removeView(it) } }
        overlay = null
    }

    fun clear() { main.post {
        owner = null
        token = UUID.randomUUID().toString()
        removeOverlay()
        notifications.cancel(NOTIFICATION)
        if (PhoneAutomationRelay.controls === this) PhoneAutomationRelay.controls = null
    } }

    companion object { private const val CHANNEL = "phone_automation"; private const val NOTIFICATION = 9480 }
}

internal object PhoneAutomationRelay { @Volatile var controls: PhoneAutomationControls? = null }
class PhoneAutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PhoneAutomationRelay.controls?.receive(intent.getStringExtra("token"), intent.getStringExtra("action"))
    }
}
