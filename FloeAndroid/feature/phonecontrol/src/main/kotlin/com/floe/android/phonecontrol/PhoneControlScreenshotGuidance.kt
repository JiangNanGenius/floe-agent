// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Pure, model-facing screenshot readiness and recovery guidance for
 * `system.access.status` and the trusted tool descriptors.
 *
 * This type never grants consent, launches anything or captures pixels. It
 * separates the platform's POTENTIAL capture support
 * ([PhoneControlScreenshotSupport]) from the CURRENT live readiness of one
 * task/run: the exact-task screen scope, the persisted whole-screen capture
 * setting, the access-service/arm state and the selected app ceiling are reported
 * independently. A refusal in one call never rewrites any of those choices.
 */
object PhoneControlScreenshotGuidance {
    /**
     * The platform's POTENTIAL capture support. Kept here (public) so the App
     * host can disclose it without depending on internal policy code.
     */
    fun supportForSdk(sdkInt: Int): PhoneControlScreenshotSupport = when {
        sdkInt >= 34 -> PhoneControlScreenshotSupport.WINDOW
        sdkInt >= 30 -> PhoneControlScreenshotSupport.DISPLAY
        else -> PhoneControlScreenshotSupport.NONE
    }

    data class Readiness(
        val support: PhoneControlScreenshotSupport,
        val screenScopeGranted: Boolean,
        val wholeScreenConsent: Boolean,
        val serviceUsable: Boolean,
        val taskArmed: Boolean,
        val targetAppsSelected: Boolean,
        val userStopped: Boolean,
        val taskPaused: Boolean,
        val runtimeEpochReady: Boolean,
    ) {
        private val baseReady: Boolean
            get() = runtimeEpochReady && serviceUsable && taskArmed &&
                targetAppsSelected && !userStopped && !taskPaused && screenScopeGranted

        /** Android 14+ window capture needs only the exact-task screen scope. */
        val windowCaptureReady: Boolean
            get() = baseReady && support == PhoneControlScreenshotSupport.WINDOW

        /**
         * Display capture needs the separate whole-screen capture setting on every
         * supported API level; a window capture never needs it.
         */
        val displayCaptureReady: Boolean
            get() = baseReady && support != PhoneControlScreenshotSupport.NONE &&
                wholeScreenConsent

        /** True when EITHER supported mode has its live consent satisfied. */
        val anyCaptureReady: Boolean
            get() = displayCaptureReady || windowCaptureReady

        val modeLabel: String
            get() = when (support) {
                PhoneControlScreenshotSupport.WINDOW -> "window_or_display"
                PhoneControlScreenshotSupport.DISPLAY -> "display_only"
                PhoneControlScreenshotSupport.NONE -> "none"
            }

        /** Compact status line: potential support and CURRENT consent state. */
        fun consentLine(): String =
            "screenshotSupport=${support.name.lowercase()} mode=$modeLabel " +
                "screenScope=${if (screenScopeGranted) "on" else "off"} " +
                "wholeScreenConsent=$wholeScreenConsent"

        /**
         * Exact existing recovery for the FIRST unmet live requirement. It
         * never suggests granting Play permissions, bypassing credentials or
         * re-arming automatically; those are not screenshot prerequisites.
         */
        fun recovery(): String = when {
            support == PhoneControlScreenshotSupport.NONE ->
                "This Android version has no supported capture. Display capture needs " +
                    "Android 11+; window capture needs Android 14+. VNC is a different desktop."
            !serviceUsable ->
                "Enable or reconnect the accessibility service in Settings > Device."
            !runtimeEpochReady ->
                "The task runtime is not ready; wait for it, then observe and capture again."
            userStopped ->
                "Allow device control for this task again in Settings > Device."
            taskPaused ->
                "Resume device control for this task, then observe and capture again."
            !targetAppsSelected ->
                "Select at least one target app in Settings > Device."
            !taskArmed ->
                "Allow device control for this task in Settings > Device."
            !screenScopeGranted ->
                "This run's screen scope is OFF; the separate saved whole-screen consent " +
                    "is reported independently. In Settings > Device > Screen content " +
                    "choose This task (or Until stopped). This task ends with this run; " +
                    "a refusal does not change your selected apps."
            support == PhoneControlScreenshotSupport.DISPLAY && !wholeScreenConsent ->
                "Android 11-13 capture the display only: also turn on whole-screen " +
                    "screenshots in Settings > Device > Screen content. Window capture " +
                    "needs Android 14+."
            support == PhoneControlScreenshotSupport.WINDOW && !wholeScreenConsent ->
                "Window capture is ready with observationId from a fresh observe; display " +
                    "capture also needs Allow whole-screen capture in Settings > Device > " +
                    "Screen content."
            support == PhoneControlScreenshotSupport.WINDOW ->
                "Ready. Pass observationId from a fresh device.observe for a window capture, " +
                    "or omit it for a display capture. Observe again after a handover or any " +
                    "screen change."
            else ->
                "Ready. Call device.screenshot without observationId for a display capture; " +
                    "window capture needs Android 14+. Observe again after a handover or any " +
                    "screen change."
        }
    }

    /**
     * Recovery for an observation/action refused because the current page is
     * outside the selected app ceiling. That refusal is page-scoped: it never
     * deselects the other target apps and never revokes a live screen scope.
     */
    fun targetPackageRecovery(): String =
        // Short enough for the bounded 200-character failure-detail channel.
        "Applies only to this page; your selected apps are unchanged. Select this " +
            "app in Settings > Device, or launch an already-selected app, then observe again."
}
