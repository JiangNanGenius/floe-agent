// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.view.accessibility.AccessibilityEvent

/**
 * The only exported component in this module, protected by
 * `android.permission.BIND_ACCESSIBILITY_SERVICE` so only the system may bind.
 * It performs no background collection: events update only generation/settle
 * counters; a node tree is read only inside an explicit host operation.
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
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> session.onWindowChanged()

            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED -> session.onContentChanged()

            // Programmatic and user scrolls/clicks both arrive here. The
            // session suppresses the short window around its own dispatch;
            // anything else is treated as user interaction evidence and
            // fences the run. This is a best-effort supplement to the
            // platform's TYPE_TOUCH_INTERACTION_START events.
            AccessibilityEvent.TYPE_VIEW_SCROLLED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_TOUCH_INTERACTION_START -> session.onPlatformUserInteraction()
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
