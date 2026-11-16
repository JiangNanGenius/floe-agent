// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import java.util.concurrent.atomic.AtomicInteger

/** Opt-in, process-bounded timing only; never receives screen or owner data. */
object PhoneControlTouchDiagnostic {
    enum class Event {
        AS_START, RAW_CLOSED, RAW_SUPPRESSED, RAW_ECHO, RAW_ACCEPT, FENCE_USER_TOUCH,
        BUBBLE_DOWN, BUBBLE_UP, BUBBLE_CANCEL, EXPAND_REQUEST, EXPAND_OPEN,
        EXPAND_UNAVAILABLE, OVERLAY_REMOVE,
    }

    private const val TAG = "FloeTouchDiag"
    private const val MAX_EVENTS = 128
    private val count = AtomicInteger()

    fun record(event: Event, eventTime: Long? = null, downTime: Long? = null, pointerCount: Int? = null) {
        runCatching {
            if (!Log.isLoggable(TAG, Log.DEBUG)) return
            while (true) {
                val current = count.get()
                if (current >= MAX_EVENTS) return
                if (count.compareAndSet(current, current + 1)) break
            }
            val message = buildString {
                append(event.name).append(" uptime=").append(SystemClock.uptimeMillis())
                if (eventTime != null) append(" event=").append(eventTime)
                if (downTime != null) append(" down=").append(downTime)
                if (pointerCount != null) append(" pointers=").append(pointerCount.coerceIn(0, 32))
            }
            Log.d(TAG, message)
        }
    }
}

/**
 * The only exported component in this module, protected by
 * `android.permission.BIND_ACCESSIBILITY_SERVICE` so only the system may bind.
 * It performs no background collection: events update only generation/settle
 * counters (window events are attributed first, and clearly unrelated
 * windows never touch the observation); a node tree is read only inside an
 * explicit host operation.
 *
 * Event text is deliberately never read here. Only the event type/timing is
 * used, so notification/IM/password content cannot enter a log or retained
 * event structure.
 */
class PhoneControlAccessibilityService : AccessibilityService() {
    private var screenReceiver: BroadcastReceiver? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        PhoneControlRuntime.attach(this)
        registerScreenStateReceiver()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val session = PhoneControlRuntime.session() ?: return
        when (event?.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> session.onWindowChanged(
                eventType = event.eventType,
                sourceWindowId = event.windowId,
                windowChanges = if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
                    event.windowChanges
                } else {
                    0
                },
                // Package attribution lets the session ignore window events
                // from unrelated packages; event text is never read here.
                packageName = event.packageName?.toString(),
            )

            // Editable fields can emit text/selection events without a window
            // content event. They affect settling, never read event.text here.
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> session.onContentChanged()

            // Programmatic and user scrolls/clicks both arrive here. Events
            // stamped with Floe's own package are ordinary App UI (the chat
            // streams and autoscrolls while its protected page stays visible
            // after an automatic unlock): a genuine user touch on Floe's own
            // Activity is reported by the trusted own-App hook, so these must
            // never fence the run. External events keep the conservative
            // user-takeover path except for the exact package this session
            // just launched inside its bounded owned-transition window.
            AccessibilityEvent.TYPE_VIEW_SCROLLED,
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                when (
                    PhoneControlPolicy.semanticInteractionOrigin(
                        event.packageName?.toString(),
                        ownAppPackageName = this.packageName,
                    )
                ) {
                    PhoneInteractionOrigin.OWN_APP_SEMANTIC ->
                        session.onOwnAppSemanticEvent()
                    PhoneInteractionOrigin.EXTERNAL_SEMANTIC ->
                        session.onExternalSemanticInteraction(
                            packageName = event.packageName?.toString(),
                            eventUptimeMillis = event.eventTime,
                        )
                }
            }

            // Raw touch interaction: the unambiguous human signal, with the
            // session's existing own-dispatch echo attribution. The session's
            // owned-view transition never absorbs this.
            AccessibilityEvent.TYPE_TOUCH_INTERACTION_START -> {
                PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.AS_START, eventTime = event.eventTime)
                session.onRawTouchInteraction(event.eventTime)
            }
        }
    }

    override fun onInterrupt() {
        PhoneControlRuntime.session()?.onServiceInterrupt()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        unregisterScreenStateReceiver()
        PhoneControlRuntime.detach(this, PhoneControlBlocker.SERVICE_REVOKED)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        unregisterScreenStateReceiver()
        PhoneControlRuntime.detach(this, PhoneControlBlocker.SERVICE_REVOKED)
        super.onDestroy()
    }

    private fun registerScreenStateReceiver() {
        if (screenReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val session = PhoneControlRuntime.session() ?: return
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF -> session.onScreenOff()
                    Intent.ACTION_SCREEN_ON,
                    Intent.ACTION_USER_PRESENT -> session.onScreenInteractive()
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        // Exclusively protected system broadcasts. API 33+ requires an
        // explicit exported/not-exported flag for context receivers; system
        // broadcasts cannot be spoofed by other apps, so EXPORTED is safe here.
        runCatching {
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                registerReceiver(receiver, filter)
            }
        }.onSuccess { screenReceiver = receiver }
    }

    private fun unregisterScreenStateReceiver() {
        val receiver = screenReceiver ?: return
        screenReceiver = null
        runCatching { unregisterReceiver(receiver) }
    }
}
