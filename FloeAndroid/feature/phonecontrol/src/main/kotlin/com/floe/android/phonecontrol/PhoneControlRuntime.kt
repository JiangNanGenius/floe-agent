// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The one live phone-control service/session registry. The AccessibilityService
 * is created by the system, never by the host; callers obtain operations through
 * [PhoneControlModule.client]. Status is published from actual attach/detach and
 * fence transitions, so capability reporting never assumes `AVAILABLE`.
 */
internal object PhoneControlRuntime {
    private val gate = Any()
    @Volatile private var current: PhoneControlSession? = null
    @Volatile private var currentService: PhoneControlAccessibilityService? = null
    @Volatile private var enabledHint = false
    @Volatile private var detachedBlocker: PhoneControlBlocker? = null
    @Volatile private var lastFenceGeneration = 0L
    @Volatile private var lastPageGeneration = 0L

    private val mutableStatus = MutableStateFlow(
        PhoneControlStatus(
            connected = false,
            enabled = false,
            blocker = null,
            activeOwner = null,
            fenceGeneration = 0,
            pageGeneration = 0,
            screenshotSupport = PhoneControlPolicy.screenshotSupport(Build.VERSION.SDK_INT),
        ),
    )
    val status: StateFlow<PhoneControlStatus> = mutableStatus.asStateFlow()

    internal fun attach(service: PhoneControlAccessibilityService): PhoneControlSession {
        val newSession = PhoneControlSession(service)
        val previous = synchronized(gate) {
            val old = current
            current = newSession
            currentService = service
            enabledHint = true
            detachedBlocker = null
            old
        }
        previous?.shutdown(PhoneControlBlocker.SERVICE_DISCONNECTED)
        publish()
        return newSession
    }

    internal fun detach(service: PhoneControlAccessibilityService, blocker: PhoneControlBlocker) {
        val removed: PhoneControlSession?
        synchronized(gate) {
            if (currentService !== service) return
            val state = current?.fence?.state()
            if (state != null) {
                lastFenceGeneration = state.fenceGeneration
                lastPageGeneration = state.pageGeneration
            }
            removed = current
            current = null
            currentService = null
            enabledHint = false
            detachedBlocker = blocker
        }
        removed?.shutdown(blocker)
        publish()
    }

    internal fun session(): PhoneControlSession? = current

    internal fun snapshot(): PhoneControlStatus {
        val session = current
        val state = session?.fence?.state()
        return PhoneControlStatus(
            connected = session != null,
            enabled = session != null || enabledHint,
            blocker = if (session != null) state?.blocker else detachedBlocker,
            activeOwner = if (session != null) state?.owner else null,
            fenceGeneration = state?.fenceGeneration ?: lastFenceGeneration,
            pageGeneration = state?.pageGeneration ?: lastPageGeneration,
            screenshotSupport = PhoneControlPolicy.screenshotSupport(Build.VERSION.SDK_INT),
        )
    }

    /** Called by the activation check so the status flow reflects the system setting. */
    internal fun noteEnabled(value: Boolean) {
        if (enabledHint == value) return
        enabledHint = value
        publish()
    }

    internal fun publish() {
        val next = snapshot()
        lastFenceGeneration = next.fenceGeneration
        lastPageGeneration = next.pageGeneration
        mutableStatus.value = next
    }
}
