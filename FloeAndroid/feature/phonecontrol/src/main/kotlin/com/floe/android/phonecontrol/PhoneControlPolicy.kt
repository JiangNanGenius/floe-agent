// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Pure authorization/target/privacy policy. Every function is deterministic
 * and Android-free so the exact gate can be unit-tested without a device.
 *
 * The host's live grant is the only authority. `allowedPackages` on the
 * principal is a requested scope that can only be narrowed by the grant;
 * neither an opaque node ref nor an earlier observation authorizes anything.
 */
internal object PhoneControlPolicy {
    // AOSP AccessibilityWindowInfo.TYPE_SYSTEM. Kept as a pure constant so this
    // file stays JVM-testable; the Android snapshotter passes window.type.
    const val WINDOW_TYPE_APPLICATION = 1
    const val WINDOW_TYPE_SYSTEM = 3

    const val SYSTEM_UI_PACKAGE = "com.android.systemui"

    /**
     * Stable applicationId root shared by every shipped Floe App/runtime
     * channel. The runtime component is a sibling package
     * (`com.floe.agent.runtime[.full][.dev]`), not a child of the hosting App
     * package, so this parent covers Play/Full/debug and the sibling runtime.
     */
    const val FLOE_PACKAGE_ROOT = "com.floe.agent"

    private val PROTECTED_PACKAGES = setOf(
        SYSTEM_UI_PACKAGE,
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
    )

    private val PROTECTED_CLASS_MARKERS = listOf(
        "keyguard",
        "confirmdevicecredential",
        "confirmlock",
        "chooselock",
        "biometricenrollment",
        "fingerprintenrollment",
        "credentialenrollment",
        "screenlock",
    )

    fun principalDenial(principal: PhoneControlPrincipal): PhoneControlDenial? {
        if (principal.epoch < 0 || principal.generation < 0) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        if (principal.allowedPackages.size > PhoneControlLimits.MAX_TARGET_PACKAGES) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        if (principal.allowedPackages.any { packageDenial(it) != null }) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        val callID = principal.callID
        if (callID != null && (callID.isBlank() || callID.length > 200)) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        return null
    }

    fun grantDenial(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
    ): PhoneControlDenial? {
        if (grant.owner != principal.owner) return PhoneControlDenial.AUTHORIZATION_STALE
        if (grant.epoch != principal.epoch || grant.generation != principal.generation) {
            return PhoneControlDenial.AUTHORIZATION_STALE
        }
        if (grant.grantID != principal.grantID) {
            return PhoneControlDenial.AUTHORIZATION_STALE
        }
        if (grant.allowedPackages.size > PhoneControlLimits.MAX_TARGET_PACKAGES) {
            return PhoneControlDenial.AUTHORIZATION_DENIED
        }
        if (grant.allowedPackages.any { packageDenial(it) != null }) {
            return PhoneControlDenial.AUTHORIZATION_DENIED
        }
        return null
    }

    /** Intersection: the live grant can only narrow what the caller requested. */
    fun effectivePackages(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
    ): Set<String> = (principal.allowedPackages intersect grant.allowedPackages)
        .filterNot { isFloePackage(it) }
        .toSet()

    /**
     * Decide whether the current foreground may be observed at all.
     *
     * Floe's own App/runtime windows are never returned as a tree. A task that
     * is armed while Floe is foreground still needs a real fenced observation
     * to authorize leaving Floe, so exactly one narrow exception exists: the
     * snapshotter's zero-node metadata observation, and only when the live
     * grant explicitly allows global navigation. [navigationMetadataOnly] is
     * set by that snapshotter path; a full Floe observation is always denied.
     */
    fun observationDenial(
        packageName: String?,
        effectivePackages: Set<String>,
        homePackage: String?,
        allowGlobalNavigation: Boolean,
        navigationMetadataOnly: Boolean = false,
    ): PhoneControlDenial? {
        if (packageName.isNullOrBlank()) return PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
        // A stale/erroneous grant that still lists the App or its runtime
        // sibling must not expose Floe's own settings/approval surfaces.
        if (isFloePackage(packageName)) {
            return if (allowGlobalNavigation && navigationMetadataOnly) {
                null
            } else {
                PhoneControlDenial.PROTECTED_WINDOW
            }
        }
        if (packageName in effectivePackages) return null
        if (allowGlobalNavigation &&
            (packageName == homePackage || packageName == SYSTEM_UI_PACKAGE)
        ) {
            return null
        }
        return PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
    }

    fun nodeTargetDenial(
        nodePackage: String?,
        observationPackage: String?,
        effectivePackages: Set<String>,
    ): PhoneControlDenial? {
        val target = nodePackage ?: observationPackage
        if (target.isNullOrBlank()) return PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
        // Checked before the membership test so an erroneously listed self
        // package is still refused as protected instead of being allowed.
        if (isFloePackage(target)) return PhoneControlDenial.PROTECTED_WINDOW
        if (target !in effectivePackages) {
            return PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
        }
        return null
    }

    fun fieldActionDenial(record: PhoneControlNodeRecord): PhoneControlDenial? =
        if (record.password || record.redacted) PhoneControlDenial.SENSITIVE_FIELD else null

    fun launchDenial(
        targetPackage: String,
        effectivePackages: Set<String>,
    ): PhoneControlDenial? {
        packageDenial(targetPackage)?.let { return it }
        // Refuse Floe's own App/runtime family even if a stale grant lists it.
        if (isFloePackage(targetPackage)) return PhoneControlDenial.PROTECTED_WINDOW
        if (targetPackage !in effectivePackages) {
            return PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
        }
        if (isProtectedPackage(targetPackage)) return PhoneControlDenial.PROTECTED_WINDOW
        return null
    }

    fun isProtectedPackage(packageName: String?): Boolean =
        packageName != null &&
            (packageName in PROTECTED_PACKAGES || isFloePackage(packageName))

    /**
     * True for the stable Floe App/runtime family. Separator-aware so an
     * unrelated package such as `com.floe.agentic` is never swept in.
     */
    fun isFloePackage(packageName: String?): Boolean {
        if (packageName.isNullOrEmpty()) return false
        return packageName == FLOE_PACKAGE_ROOT ||
            packageName.startsWith("$FLOE_PACKAGE_ROOT.")
    }

    /**
     * System UI, permission-installer dialogs, Floe's own App/runtime windows,
     * lock/credential/enrollment screens, and system password dialogs are
     * protected. A user app login screen is not a protected window, but its
     * password fields are redacted and refuse setText; screenshots are still
     * refused for any visible password field by [screenshotDenial].
     */
    fun isProtectedWindow(
        packageName: String?,
        className: String?,
        windowType: Int?,
        hasPassword: Boolean,
        keyguardLocked: Boolean,
    ): Boolean {
        if (keyguardLocked) return true
        val pkg = packageName.orEmpty()
        if (isProtectedPackage(pkg)) return true
        val cls = className.orEmpty().lowercase()
        if (PROTECTED_CLASS_MARKERS.any { marker -> cls.contains(marker) }) return true
        if (windowType == WINDOW_TYPE_SYSTEM && (pkg == "android" || pkg.startsWith("com.android."))) {
            return true
        }
        return hasPassword && (pkg == "android" || pkg.startsWith("com.android."))
    }

    fun nodeActionDenial(
        packageName: String?,
        className: String?,
        windowType: Int?,
        hasPassword: Boolean,
        keyguardLocked: Boolean,
    ): PhoneControlDenial? =
        if (isProtectedWindow(packageName, className, windowType, hasPassword, keyguardLocked)) {
            PhoneControlDenial.PROTECTED_WINDOW
        } else {
            null
        }

    /**
     * A navigation-only observation carries no node records at all. It may
     * authorize only the existing global Back/Home actions or a Launch whose
     * target already passed [launchDenial]; every node-targeted action remains
     * refused as a protected Floe window even if a caller supplies a made-up
     * ref. Launch of a Floe package stays denied by [launchDenial]. The live
     * grant must still allow global navigation at dispatch time.
     */
    fun navigationOnlyActionDenial(
        navigationOnly: Boolean,
        allowGlobalNavigation: Boolean,
        action: PhoneControlAction,
    ): PhoneControlDenial? {
        if (!navigationOnly) return null
        // The metadata record only exists because the live grant allowed
        // navigation at observation time. Re-check it at dispatch so a revoked
        // grant cannot still use the record.
        if (!allowGlobalNavigation) return PhoneControlDenial.AUTHORIZATION_DENIED
        return when (action) {
            PhoneControlAction.Back,
            PhoneControlAction.Home,
            is PhoneControlAction.Launch,
            -> null
            is PhoneControlAction.Click,
            is PhoneControlAction.SetText,
            is PhoneControlAction.Scroll,
            is PhoneControlAction.Swipe,
            -> PhoneControlDenial.PROTECTED_WINDOW
        }
    }

    fun screenshotDenial(
        allowScreenshot: Boolean,
        keyguardLocked: Boolean,
        protectedWindow: Boolean,
        hasPassword: Boolean,
    ): PhoneControlDenial? = when {
        !allowScreenshot -> PhoneControlDenial.AUTHORIZATION_DENIED
        keyguardLocked -> PhoneControlDenial.DEVICE_LOCKED
        protectedWindow -> PhoneControlDenial.PROTECTED_WINDOW
        hasPassword -> PhoneControlDenial.PROTECTED_WINDOW
        else -> null
    }

    fun isDeviceLocked(interactive: Boolean, keyguardLocked: Boolean): Boolean =
        !interactive || keyguardLocked

    fun screenshotSupport(sdkInt: Int): PhoneControlScreenshotSupport = when {
        sdkInt >= 34 -> PhoneControlScreenshotSupport.WINDOW
        sdkInt >= 30 -> PhoneControlScreenshotSupport.DISPLAY
        else -> PhoneControlScreenshotSupport.NONE
    }

    fun screenChanged(
        previousFingerprint: Long,
        previousPackage: String?,
        previousWindowId: Int,
        nextFingerprint: Long,
        nextPackage: String?,
        nextWindowId: Int,
    ): Boolean = previousFingerprint != nextFingerprint ||
        previousPackage != nextPackage ||
        previousWindowId != nextWindowId

    fun denialForBlocker(blocker: PhoneControlBlocker): PhoneControlDenial = when (blocker) {
        PhoneControlBlocker.STOPPED -> PhoneControlDenial.STOPPED
        PhoneControlBlocker.TAKEN_OVER -> PhoneControlDenial.TAKEN_OVER
        PhoneControlBlocker.USER_TOUCH -> PhoneControlDenial.USER_TOUCH
        PhoneControlBlocker.LOCKED -> PhoneControlDenial.DEVICE_LOCKED
        PhoneControlBlocker.SERVICE_REVOKED -> PhoneControlDenial.SERVICE_REVOKED
        PhoneControlBlocker.SERVICE_DISCONNECTED -> PhoneControlDenial.SERVICE_DISCONNECTED
    }

    private fun packageDenial(packageName: String): PhoneControlDenial? {
        if (packageName.isBlank() || packageName.length > PhoneControlLimits.MAX_PACKAGE_CHARS) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        if (packageName.any { ch -> ch.isWhitespace() || ch == '/' }) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        return null
    }
}

/** One observable window visible on the captured display. */
internal data class PhoneControlDisplayWindow(
    val windowId: Int,
    val packageName: String?,
    val windowType: Int?,
    val bounds: PhoneControlBounds,
)

/** Exact target identity stamped before a screenshot request. */
internal data class PhoneControlCaptureStamp(
    val fenceGeneration: Long,
    val pageGeneration: Long,
    val windowId: Int,
    val packageName: String?,
)

/**
 * A whole-display capture includes every visible window. The observed app,
 * the home window and the system status/navigation bars are safe; any other
 * visible window (IME, notification shade, permission/system dialog, foreign
 * split-screen app, toast, overlay) makes the capture unscoped and is refused.
 * Window-scoped API 34 capture does not use this scan.
 */
internal fun displayCaptureDenial(
    windows: List<PhoneControlDisplayWindow>,
    observedWindowId: Int,
    observedPackage: String?,
    homePackage: String?,
    displayBounds: PhoneControlBounds,
): PhoneControlDenial? {
    val displayArea = displayBounds.width.toLong() * displayBounds.height.toLong()
    if (displayArea <= 0L) return PhoneControlDenial.PROTECTED_WINDOW
    // A whole-display image must never contain Floe's own UI even if a stale
    // observation/grant claims the Floe window is the authorized target.
    if (PhoneControlPolicy.isFloePackage(observedPackage)) {
        return PhoneControlDenial.PROTECTED_WINDOW
    }
    for (window in windows) {
        val packageName = window.packageName
        if (PhoneControlPolicy.isFloePackage(packageName)) {
            return PhoneControlDenial.PROTECTED_WINDOW
        }
        if (window.windowId == observedWindowId) continue
        if (window.bounds.isEmpty) continue
        if (packageName != null && packageName == observedPackage) continue
        if (packageName != null && packageName == homePackage &&
            window.windowType == PhoneControlPolicy.WINDOW_TYPE_APPLICATION
        ) {
            continue
        }
        if (packageName == PhoneControlPolicy.SYSTEM_UI_PACKAGE &&
            isSystemBar(window.bounds, displayBounds)
        ) {
            continue
        }
        return PhoneControlDenial.PROTECTED_WINDOW
    }
    return null
}

private fun isSystemBar(
    bounds: PhoneControlBounds,
    display: PhoneControlBounds,
): Boolean {
    if (bounds.width <= 0 || bounds.height <= 0) return false
    val topBar = bounds.top <= display.top + 2 &&
        bounds.bottom <= display.top + (display.height / 20).coerceAtLeast(1)
    val bottomBar = bounds.bottom >= display.bottom - 2 &&
        bounds.top >= display.bottom - (display.height / 12).coerceAtLeast(1)
    // Landscape navigation bars sit on a side edge and must also be treated
    // as system chrome, not as an unknown overlay.
    val leftBar = bounds.left <= display.left + 2 &&
        bounds.right <= display.left + (display.width / 12).coerceAtLeast(1)
    val rightBar = bounds.right >= display.right - 2 &&
        bounds.left >= display.right - (display.width / 12).coerceAtLeast(1)
    return topBar || bottomBar || leftBar || rightBar
}

/**
 * Completion guard for a screenshot: the exact fence/page/window/package that
 * was privacy-checked must still match after the asynchronous system capture.
 * A page change is rejected, never followed by a blind recapture.
 */
internal fun captureCompletionDenial(
    stamp: PhoneControlCaptureStamp,
    verdict: PhoneControlFence.Verdict,
    currentFenceGeneration: Long,
    currentPageGeneration: Long,
    currentWindowId: Int?,
    currentPackage: String?,
    observedPackageAllowed: Boolean,
): PhoneControlDenial? {
    return when (verdict) {
        is PhoneControlFence.Verdict.Blocked ->
            PhoneControlPolicy.denialForBlocker(verdict.blocker)
        PhoneControlFence.Verdict.ForeignRun -> PhoneControlDenial.FOREIGN_RUN
        PhoneControlFence.Verdict.StaleFence,
        PhoneControlFence.Verdict.StalePage -> PhoneControlDenial.STALE_OBSERVATION
        PhoneControlFence.Verdict.Open -> {
            // The stamp is the exact generation privacy-checked before the
            // async capture. Any drift is rejected even if the fence verdict
            // object was built from a stale ticket.
            if (stamp.fenceGeneration != currentFenceGeneration ||
                stamp.pageGeneration != currentPageGeneration
            ) {
                PhoneControlDenial.STALE_OBSERVATION
            } else when {
                currentWindowId != stamp.windowId -> PhoneControlDenial.WINDOW_CHANGED
                currentPackage != stamp.packageName -> PhoneControlDenial.FOREGROUND_CHANGED
                !observedPackageAllowed -> PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
                else -> null
            }
        }
    }
}
