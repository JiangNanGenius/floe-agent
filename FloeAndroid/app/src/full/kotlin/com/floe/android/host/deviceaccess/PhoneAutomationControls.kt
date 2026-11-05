// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.Activity
import android.app.AlertDialog
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import androidx.core.app.NotificationCompat
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.phonecontrol.PhoneControlOwner
import java.lang.ref.WeakReference
import java.util.UUID
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** Process-local, revocable controls. Notifications cannot revive a past run. */
internal class PhoneAutomationControls(private val context: Context, private val stop: () -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val windows = context.getSystemService(WindowManager::class.java)
    private var activity = WeakReference<Activity>(null)
    private var owner: PhoneControlOwner? = null
    private var token = UUID.randomUUID().toString()
    private var overlay: Button? = null
    private var dialog: AlertDialog? = null
    private var consent: ((Boolean) -> Unit)? = null
    private var waiting = false
    private var title = ""
    private var showOverlay = false

    fun attach(activity: Activity?) { main.post {
        this.activity = WeakReference(activity)
        if (waiting && activity != null) showDialog()
    } }

    fun show(owner: PhoneControlOwner, title: String, overlay: Boolean) { main.post {
        if (this.owner != owner) {
            consent?.invoke(false)
            token = UUID.randomUUID().toString()
        }
        this.owner = owner
        this.title = title
        showOverlay = overlay
        PhoneAutomationRelay.controls = this
        render()
    } }

    suspend fun confirmWhileInUse(): Boolean = suspendCancellableCoroutine { continuation ->
        main.post {
            if (!continuation.isActive || owner == null) {
                if (continuation.isActive) continuation.resume(false)
                return@post
            }
            consent?.invoke(false)
            waiting = true
            var answered = false
            val timeout = Runnable { answer(false) }
            consent = { allowed ->
                if (!answered) {
                    answered = true
                    main.removeCallbacks(timeout)
                    waiting = false
                    consent = null
                    dialog?.dismiss()
                    dialog = null
                    render()
                    if (continuation.isActive) continuation.resume(allowed)
                }
            }
            continuation.invokeOnCancellation { main.post { if (!answered) answer(false) } }
            main.postDelayed(timeout, 120_000)
            render()
            showDialog()
        }
    }

    private fun showDialog() {
        val visible = activity.get()?.takeUnless { it.isFinishing || it.isDestroyed } ?: return
        if (dialog != null || !waiting) return
        dialog = AlertDialog.Builder(visible)
            .setTitle(R.string.phone_automation_in_use)
            .setMessage(R.string.phone_automation_in_use_hint)
            .setPositiveButton(R.string.phone_automation_allow) { _, _ -> answer(true) }
            .setNegativeButton(android.R.string.cancel) { _, _ -> answer(false) }
            .setOnCancelListener { answer(false) }.show()
    }

    internal fun receive(receivedToken: String?, action: String?) { main.post {
        if (owner == null || token != receivedToken) return@post
        if (action == "allow" && waiting) answer(true)
        else if (action == "stop") { answer(false); stop() }
    } }

    private fun answer(allowed: Boolean) { consent?.invoke(allowed) }

    private fun render() {
        if (owner == null) return
        runCatching {
            notifications.createNotificationChannel(NotificationChannel(CHANNEL,
                context.getString(R.string.phone_automation_title), NotificationManager.IMPORTANCE_DEFAULT))
            val launch = PendingIntent.getActivity(context, 9481,
                Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            fun action(name: String, request: Int) = PendingIntent.getBroadcast(context, request,
                Intent(context, PhoneAutomationReceiver::class.java).putExtra("token", token).putExtra("action", name),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(context.getString(if (waiting) R.string.phone_automation_in_use else R.string.phone_automation_title))
                .setContentText(title).setContentIntent(launch).setOngoing(true).setOnlyAlertOnce(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .addAction(0, context.getString(R.string.phone_automation_stop), action("stop", 9482))
            if (waiting) builder.addAction(0, context.getString(R.string.phone_automation_allow), action("allow", 9483))
            notifications.notify(NOTIFICATION, builder.build())
        }
        if (showOverlay && Settings.canDrawOverlays(context) && overlay == null) {
            runCatching {
                val button = Button(context).apply {
                    text = context.getString(R.string.phone_automation_stop)
                    contentDescription = text
                    setOnClickListener { answer(false); stop() }
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
        answer(false)
        owner = null
        token = UUID.randomUUID().toString()
        dialog?.dismiss(); dialog = null
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
