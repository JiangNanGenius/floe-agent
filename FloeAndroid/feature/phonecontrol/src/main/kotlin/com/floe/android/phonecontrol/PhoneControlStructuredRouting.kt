// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Pure, non-authorizing routing policy between the two REAL structured UI
 * sources. Accessibility remains preferred while it is usable; a genuinely
 * live/verified ADB UI backend is offered when Accessibility is absent. This
 * object never grants an operation: the host grant, live epoch, target-app
 * ceiling, screen consent and observation fence still decide dispatch.
 */
enum class PhoneControlStructuredSource {
    ACCESSIBILITY,
    ADB_UI_AUTOMATION,
    NONE,
    ;

    val backend: PhoneControlBackend?
        get() = when (this) {
            ACCESSIBILITY -> PhoneControlBackend.ACCESSIBILITY
            ADB_UI_AUTOMATION -> PhoneControlBackend.ADB_UI_AUTOMATION
            NONE -> null
        }
}

object PhoneControlStructuredRouting {

    /**
     * Observation source preference. A ready ADB tier is deliberately not
     * hidden merely because the accessibility service is off; a transiently
     * "connected" service that is actually fenced must not win.
     */
    fun observationSource(
        accessibilityUsable: Boolean,
        adbUiReady: Boolean,
    ): PhoneControlStructuredSource = when {
        accessibilityUsable -> PhoneControlStructuredSource.ACCESSIBILITY
        adbUiReady -> PhoneControlStructuredSource.ADB_UI_AUTOMATION
        else -> PhoneControlStructuredSource.NONE
    }

    /**
     * Read-only observation fallback. Only a genuinely unavailable
     * accessibility backend may move to ADB. A denied/window-changed/stale
     * observation is a real refusal, never a cue to silently read a different
     * backend, and a short/truncated/text-capped page is not absence.
     */
    fun canFallbackToAdbForRead(
        reason: PhoneControlUnavailable,
        adbUiReady: Boolean,
    ): Boolean = adbUiReady && when (reason) {
        PhoneControlUnavailable.SERVICE_NOT_CONNECTED,
        PhoneControlUnavailable.SERVICE_NOT_ENABLED,
        -> true
        else -> false
    }

    fun canFallbackToAdbForRead(
        reason: PhoneControlDenial,
        adbUiReady: Boolean,
    ): Boolean = adbUiReady && reason == PhoneControlDenial.SERVICE_DISCONNECTED

    /**
     * Refuse a repeated mutation until a real observation has established the
     * effect of an ACCEPTED/UNKNOWN dispatch. NOT_DISPATCHED/REJECTED did not
     * mutate and may be corrected after a fresh observation, not replayed
     * under another backend.
     */
    fun requiresReadback(dispatch: PhoneControlDispatch): Boolean =
        dispatch == PhoneControlDispatch.ACCEPTED ||
            dispatch == PhoneControlDispatch.UNKNOWN ||
            dispatch == PhoneControlDispatch.PARTIAL

    /** An observation id selects exactly one backend for its lifetime. */
    fun sourceForObservation(
        observationId: String,
        accessibilityUsable: Boolean,
        adbUiReady: Boolean,
    ): PhoneControlStructuredSource {
        val backend = PhoneControlBackend.fromObservationId(observationId)
            ?: return PhoneControlStructuredSource.NONE
        return when (backend) {
            PhoneControlBackend.ACCESSIBILITY ->
                if (accessibilityUsable) PhoneControlStructuredSource.ACCESSIBILITY
                else PhoneControlStructuredSource.NONE
            PhoneControlBackend.ADB_UI_AUTOMATION ->
                if (adbUiReady) PhoneControlStructuredSource.ADB_UI_AUTOMATION
                else PhoneControlStructuredSource.NONE
        }
    }

    /** True when the chip should be shown at all. */
    fun available(
        targetPackagesSelected: Boolean,
        accessibilityUsable: Boolean,
        adbUiReady: Boolean,
    ): Boolean = targetPackagesSelected && (accessibilityUsable || adbUiReady)
}
