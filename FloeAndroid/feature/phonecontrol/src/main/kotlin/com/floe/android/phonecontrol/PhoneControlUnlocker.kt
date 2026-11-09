// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.os.Handler

/** Host-only result. No lock-screen nodes or credentials enter model observations. */
enum class PhoneUnlockResult { ALREADY_UNLOCKED, UNLOCKED, USER_REQUIRED, CANCELLED, FAILED }
enum class PhoneRelockResult { LOCKED, ALREADY_LOCKED, USER_TAKEN_OVER, USER_REQUIRED }
data class PhoneRelockReceipt(val owner: PhoneControlOwner, val result: PhoneRelockResult)

/** Effects stay on the AccessibilityService main looper; tests use a deterministic clock. */
internal interface PhoneUnlockDriver {
    val locked: Boolean
    val now: Long
    fun after(delay: Long, action: () -> Unit): () -> Unit
    fun suppressInput(until: Long)
    fun wake()
    fun showCredential(): Boolean
    fun enterCredential(secret: CharArray): Boolean
    fun requestLock(): Boolean
}

/** One bounded attempt and an observed, exact-owner cleanup; never adopts a prior process lease. */
internal class PhoneControlUnlocker(
    private val driver: PhoneUnlockDriver,
    private val stateChanged: () -> Unit = {},
) {
    constructor(service: AccessibilityService, handler: Handler,
        suppressGeneratedEvents: (Long) -> Unit, stateChanged: () -> Unit = {}) :
        this(AndroidPhoneUnlockDriver(service, handler, suppressGeneratedEvents), stateChanged)

    private class Attempt(val owner: PhoneControlOwner, val token: String, val credential: CharArray,
        val current: () -> Boolean, val complete: (PhoneUnlockResult) -> Unit) {
        var effectIssued = false
        var timer: (() -> Unit)? = null
    }
    private class Settlement(val owner: PhoneControlOwner, val deadline: Long, val mayComplete: Boolean) {
        var lockRequested = false
        var timer: (() -> Unit)? = null
    }
    private val attempted = LinkedHashSet<PhoneControlOwner>()
    private var attempt: Attempt? = null
    private var unlockedFor: PhoneControlOwner? = null
    private var settlement: Settlement? = null
    val isSettling: Boolean get() = settlement != null
    var lastRelockReceipt: PhoneRelockReceipt? = null
        private set

    fun userInteraction() {
        val owner = attempt?.owner ?: settlement?.owner ?: unlockedFor
        unlockedFor = null
        settlement?.timer?.invoke()
        settlement = null
        attempt?.let { finishAttempt(it, PhoneUnlockResult.CANCELLED, relinquished = true) }
        if (owner != null) report(owner, PhoneRelockResult.USER_TAKEN_OVER)
    }

    fun unlock(owner: PhoneControlOwner, token: String, credential: CharArray,
        isCurrent: () -> Boolean, complete: (PhoneUnlockResult) -> Unit) {
        if (attempt != null || settlement != null || !runCatching(isCurrent).getOrDefault(false) ||
            (unlockedFor != null && unlockedFor != owner)) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.CANCELLED); return
        }
        val locked = runCatching { driver.locked }.getOrNull()
        if (locked == null) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.FAILED); return
        }
        if (!locked) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.ALREADY_UNLOCKED); return
        }
        if (credential.isEmpty() || credential.size > 64 || !attempted.add(owner)) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.USER_REQUIRED); return
        }
        while (attempted.size > 64) attempted.remove(attempted.first())
        val current = Attempt(owner, token, credential, isCurrent, complete)
        attempt = current
        try {
            driver.suppressInput(driver.now + 6_000)
            // Wake may itself complete a trusted system unlock. Any uncertain
            // cancellation after an effect therefore needs observed settlement.
            current.effectIssued = true
            driver.wake()
            later(current, 400) {
                if (!driver.locked) finishAttempt(current, PhoneUnlockResult.UNLOCKED)
                else if (!driver.showCredential()) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
                else later(current, 700) {
                    if (!driver.locked) finishAttempt(current, PhoneUnlockResult.UNLOCKED)
                    else if (!driver.enterCredential(current.credential)) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
                    else later(current, 1_200) {
                        finishAttempt(current, if (!driver.locked) PhoneUnlockResult.UNLOCKED
                            else PhoneUnlockResult.USER_REQUIRED)
                    }
                }
            }
        } catch (_: Exception) { finishAttempt(current, PhoneUnlockResult.FAILED) }
    }

    private fun later(current: Attempt, delay: Long, action: () -> Unit) {
        current.timer = driver.after(delay) {
            current.timer = null
            if (attempt !== current) return@after
            if (!runCatching(current.current).getOrDefault(false)) finishAttempt(current, PhoneUnlockResult.CANCELLED)
            else try { action() } catch (_: Exception) { finishAttempt(current, PhoneUnlockResult.FAILED) }
        }
    }

    private fun finishAttempt(current: Attempt, result: PhoneUnlockResult, relinquished: Boolean = false) {
        if (attempt !== current) return
        attempt = null
        current.timer?.invoke(); current.timer = null
        current.credential.fill('\u0000')
        driver.suppressInput(driver.now + 150)
        val actualUnlocked = runCatching { !driver.locked }.getOrDefault(false)
        if (!relinquished && actualUnlocked && current.effectIssued) unlockedFor = current.owner
        val actualResult = if (result == PhoneUnlockResult.UNLOCKED && !actualUnlocked)
            PhoneUnlockResult.USER_REQUIRED else result
        if (!relinquished && actualResult != PhoneUnlockResult.UNLOCKED && current.effectIssued) {
            // An in-flight system transition may finish after Cancel. No more
            // credential input is permitted; only observe and clean up our lease.
            settle(current.owner, mayComplete = true)
        }
        current.complete(actualResult)
    }

    fun finish(owner: PhoneControlOwner) {
        val pending = attempt
        if (pending?.owner == owner) {
            finishAttempt(pending, PhoneUnlockResult.CANCELLED)
        } else if (settlement?.owner == owner) {
            return
        } else if (unlockedFor == owner) {
            settle(owner, mayComplete = false)
        }
    }

    private fun settle(owner: PhoneControlOwner, mayComplete: Boolean) {
        if (settlement != null) return
        val value = Settlement(owner, driver.now + 1_800, mayComplete)
        settlement = value
        stateChanged()
        checkSettlement(value)
    }

    private fun checkSettlement(value: Settlement) {
        if (settlement !== value) return
        val locked = runCatching { driver.locked }.getOrNull()
        if (locked == null) { endSettlement(value, PhoneRelockResult.USER_REQUIRED); return }
        if (locked && value.lockRequested) { endSettlement(value, PhoneRelockResult.LOCKED); return }
        if (locked && (!value.mayComplete || driver.now >= value.deadline)) {
            endSettlement(value, PhoneRelockResult.ALREADY_LOCKED); return
        }
        if (!locked && !value.lockRequested) {
            value.lockRequested = true
            val accepted = runCatching { driver.requestLock() }.getOrDefault(false)
            if (!accepted) { endSettlement(value, PhoneRelockResult.USER_REQUIRED); return }
            // A true dispatch return is not proof of actual keyguard state.
        }
        if (driver.now >= value.deadline) { endSettlement(value, PhoneRelockResult.USER_REQUIRED); return }
        try { value.timer = driver.after(100) { value.timer = null; checkSettlement(value) } }
        catch (_: Exception) { endSettlement(value, PhoneRelockResult.USER_REQUIRED) }
    }

    private fun endSettlement(value: Settlement, result: PhoneRelockResult) {
        if (settlement !== value) return
        value.timer?.invoke()
        settlement = null
        if (unlockedFor == value.owner) unlockedFor = null
        report(value.owner, result)
    }

    private fun report(owner: PhoneControlOwner, result: PhoneRelockResult) {
        lastRelockReceipt = PhoneRelockReceipt(owner, result)
        stateChanged()
    }

    fun cancel(token: String) {
        attempt?.takeIf { it.token == token }?.let { finishAttempt(it, PhoneUnlockResult.CANCELLED) }
    }

    fun close() {
        // Service teardown ends this incarnation's authority. Never leave a
        // delayed cleanup capable of locking a replacement session/user.
        val pending = attempt
        val owner = pending?.owner ?: settlement?.owner ?: unlockedFor
        val uncertainInput = pending?.effectIssued == true
        settlement?.timer?.invoke()
        settlement = null
        unlockedFor = null
        pending?.let { finishAttempt(it, PhoneUnlockResult.CANCELLED, relinquished = true) }
        if (owner != null) report(owner,
            if (!uncertainInput && runCatching { driver.locked }.getOrDefault(false))
                PhoneRelockResult.ALREADY_LOCKED else PhoneRelockResult.USER_REQUIRED)
    }
}
