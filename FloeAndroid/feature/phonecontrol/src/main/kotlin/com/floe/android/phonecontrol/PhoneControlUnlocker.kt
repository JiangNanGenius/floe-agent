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

/** Host-only result. No lock-screen nodes or credentials enter model observations. */
enum class PhoneUnlockResult { ALREADY_UNLOCKED, UNLOCKED, USER_REQUIRED, CANCELLED, FAILED }

/** One bounded attempt per owner, including cancellation and uncertain outcomes. */
internal class PhoneControlUnlocker(
    private val service: AccessibilityService,
    private val handler: Handler,
    private val suppressGeneratedEvents: (Long) -> Unit,
) {
    private val keyguard = service.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private val power = service.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val attempted = LinkedHashSet<PhoneControlOwner>()
    private var unlockedFor: PhoneControlOwner? = null
    private var pending: Runnable? = null
    private var abort: (() -> Unit)? = null
    private var operationToken: String? = null

    fun userInteraction() {
        // A human takes ownership immediately; task completion must not lock them out.
        unlockedFor = null
        abort?.invoke()
    }

    fun unlock(
        owner: PhoneControlOwner,
        token: String,
        credential: CharArray,
        isCurrent: () -> Boolean,
        complete: (PhoneUnlockResult) -> Unit,
    ) {
        if (abort != null || !isCurrent()) {
            credential.fill('\u0000')
            complete(PhoneUnlockResult.CANCELLED)
            return
        }
        if (!keyguard.isKeyguardLocked) {
            credential.fill('\u0000')
            complete(PhoneUnlockResult.ALREADY_UNLOCKED)
            return
        }
        if (credential.isEmpty() || credential.size > 64 || !attempted.add(owner)) {
            credential.fill('\u0000')
            complete(PhoneUnlockResult.USER_REQUIRED)
            return
        }
        while (attempted.size > 64) attempted.remove(attempted.first())
        operationToken = token
        var finished = false
        fun finish(result: PhoneUnlockResult) {
            if (finished) return
            finished = true
            pending?.let { handler.removeCallbacks(it) }
            pending = null
            abort = null
            operationToken = null
            suppressGeneratedEvents(SystemClock.elapsedRealtime() + 150)
            credential.fill('\u0000')
            if (result == PhoneUnlockResult.UNLOCKED) unlockedFor = owner
            complete(result)
        }
        abort = { finish(PhoneUnlockResult.CANCELLED) }
        fun later(delay: Long, action: () -> Unit) {
            val work = Runnable {
                pending = null
                if (finished) return@Runnable
                if (!isCurrent()) finish(PhoneUnlockResult.CANCELLED) else action()
            }
            pending = work
            handler.postDelayed(work, delay)
        }
        try {
            suppressGeneratedEvents(SystemClock.elapsedRealtime() + 6_000)
            @Suppress("DEPRECATION")
            power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "Floe:TaskUnlock").apply { acquire(4_000); release() }
            later(400) {
                if (!keyguard.isKeyguardLocked) {
                    finish(PhoneUnlockResult.UNLOCKED)
                } else {
                    val metrics = service.resources.displayMetrics
                    val path = Path().apply {
                        moveTo(metrics.widthPixels * .5f, metrics.heightPixels * .82f)
                        lineTo(metrics.widthPixels * .5f, metrics.heightPixels * .25f)
                    }
                    val gesture = GestureDescription.Builder()
                        .addStroke(GestureDescription.StrokeDescription(path, 0, 300)).build()
                    if (!service.dispatchGesture(gesture, null, handler)) finish(PhoneUnlockResult.USER_REQUIRED)
                    else later(700) {
                        if (!keyguard.isKeyguardLocked) finish(PhoneUnlockResult.UNLOCKED)
                        else if (!enterCredential(credential)) finish(PhoneUnlockResult.USER_REQUIRED)
                        else later(1_200) {
                            finish(if (!keyguard.isKeyguardLocked) PhoneUnlockResult.UNLOCKED
                                else PhoneUnlockResult.USER_REQUIRED)
                        }
                    }
                }
            }
        } catch (_: Exception) {
            finish(PhoneUnlockResult.FAILED)
        }
    }

    private fun enterCredential(secret: CharArray): Boolean {
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

    fun finish(owner: PhoneControlOwner) {
        if (unlockedFor != owner) return
        unlockedFor = null
        if (!keyguard.isKeyguardLocked) service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)
    }

    fun cancel(token: String) { if (operationToken == token) abort?.invoke() }

    fun close() {
        abort?.invoke()
        unlockedFor?.let(::finish)
    }
}
