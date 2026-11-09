// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.PowerManager
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo

/** Android effects for the existing task-owned unlock transaction. */
internal class AndroidPhoneUnlockDriver(
    private val service: AccessibilityService,
    private val handler: Handler,
    private val suppress: (Long) -> Unit,
) : PhoneUnlockDriver {
    private val keyguard = service.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private val power = service.getSystemService(Context.POWER_SERVICE) as PowerManager
    override val locked: Boolean get() = keyguard.isKeyguardLocked
    override val now: Long get() = SystemClock.elapsedRealtime()
    override fun suppressInput(until: Long) = suppress(until)
    override fun after(delay: Long, action: () -> Unit): () -> Unit {
        val work = Runnable { action() }
        check(handler.postDelayed(work, delay))
        return { handler.removeCallbacks(work) }
    }
    override fun wake() {
        @Suppress("DEPRECATION")
        power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "Floe:TaskUnlock").apply { acquire(4_000); release() }
    }
    override fun showCredential(): Boolean {
        val metrics = service.resources.displayMetrics
        val path = Path().apply {
            moveTo(metrics.widthPixels * .5f, metrics.heightPixels * .82f)
            lineTo(metrics.widthPixels * .5f, metrics.heightPixels * .25f)
        }
        return service.dispatchGesture(GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 300)).build(), null, handler)
    }
    override fun requestLock(): Boolean =
        service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)

    override fun enterCredential(secret: CharArray): Boolean {
        val root = service.rootInActiveWindow ?: return false
        try {
            if (root.packageName?.toString() != "com.android.systemui") return false
            val fields = listOf("passwordEntry", "pinEntry", "password_entry", "pin_entry")
            for (id in fields) {
                val nodes = root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/$id")
                try {
                    val field = nodes.firstOrNull { it.isEditable && it.isPassword }
                    if (field != null && field.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }) {
                        val value = String(secret)
                        val accepted = field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
                        })
                        if (!accepted) return false
                        return click(root, listOf("key_enter", "key_enter_text", "password_confirm", "ok"))
                    }
                } finally { nodes.forEach { @Suppress("DEPRECATION") it.recycle() } }
            }
            if (!secret.all { it in '0'..'9' }) return false
            for (digit in secret) {
                if (!click(root, listOf("key$digit", "key_$digit"))) return false
            }
            // Some configured PIN screens submit the final digit themselves.
            click(root, listOf("key_enter", "key_enter_text", "ok"))
            return true
        } finally { @Suppress("DEPRECATION") root.recycle() }
    }

    private fun click(root: AccessibilityNodeInfo, ids: List<String>): Boolean {
        for (id in ids) {
            val nodes = root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/$id")
            try {
                for (node in nodes) if (node.isEnabled && node.isClickable &&
                    node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
            } finally { nodes.forEach { @Suppress("DEPRECATION") it.recycle() } }
        }
        return false
    }

}
