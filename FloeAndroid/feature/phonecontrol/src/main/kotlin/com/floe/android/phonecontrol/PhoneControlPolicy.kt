// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID

/**
 * Origin of a platform semantic interaction event (click/scroll). Closed
 * enum for attribution/diagnostics only — it never carries event text, node
 * data, packages beyond the classification itself, coordinates or payload.
 */
internal enum class PhoneInteractionOrigin {
    /** Floe's own window: ordinary App UI, never human-takeover evidence. */
    OWN_APP_SEMANTIC,

    /** An external app's window: conservative existing takeover path. */
    EXTERNAL_SEMANTIC,
}

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

    /**
     * Field-level privacy gate for text/swipe node actions.
     *
     * Ordinary text never touches a password or sensitive-view-id field.
     * [sensitiveInput] = true is the explicit user-authorized credential
     * route: it may fill an editable protected FIELD inside an already
     * authorized non-system window, while every window-level guard
     * ([isProtectedWindow], [nodeActionDenial], [navigationOnlyActionDenial])
     * and the separate screenshot gate stay exactly as before. The supplied
     * bytes are dispatched once and the field contents are never read back.
     */
    fun fieldActionDenial(
        record: PhoneControlNodeRecord,
        sensitiveInput: Boolean = false,
    ): PhoneControlDenial? =
        if (!sensitiveInput && (record.password || record.redacted)) {
            PhoneControlDenial.SENSITIVE_FIELD
        } else {
            null
        }

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

    /**
     * Structural gate for the ONE typed background document VIEW:
     * App-owned content URI, single concrete MIME, exact package/class and a
     * bounded inert display name. It accepts no flags, extras, action or
     * authority from the caller.
     */
    fun documentViewShapeDenial(request: PhoneControlDocumentViewRequest): PhoneControlDenial? {
        if (packageDenial(request.packageName) != null) return PhoneControlDenial.INVALID_ARGUMENT
        if (!validDocumentMime(request.mimeType) ||
            !validDocumentClass(request.className) ||
            !validDocumentDisplayName(request.displayName)
        ) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        return null
    }

    /**
     * Full gate for the typed background document VIEW. [expectedAuthority]
     * is the App's own `${applicationId}.externaledits`; [effectivePackages]
     * is the live grant/principal intersection, so a revoked selection or a
     * narrowed grant refuses even when the record was staged earlier.
     *
     * System resolver identities and Floe's own App/runtime family are always
     * refused as protected windows, never silently replaced by a chooser.
     */
    fun documentViewDenial(
        request: PhoneControlDocumentViewRequest,
        expectedAuthority: String,
        effectivePackages: Set<String>,
    ): PhoneControlDenial? {
        documentViewShapeDenial(request)?.let { return it }
        if (!validDocumentUri(request.uri, expectedAuthority)) {
            return PhoneControlDenial.INVALID_ARGUMENT
        }
        val packageName = request.packageName
        if (packageName == "android" ||
            packageName.startsWith("com.android.internal.") ||
            packageName == "com.android.intentresolver" ||
            isProtectedPackage(packageName) ||
            isFloePackage(packageName)
        ) {
            return PhoneControlDenial.PROTECTED_WINDOW
        }
        if (packageName !in effectivePackages) {
            return PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED
        }
        return null
    }

    private fun validDocumentUri(uri: String, expectedAuthority: String): Boolean {
        if (expectedAuthority.isEmpty() || expectedAuthority.length > 255 ||
            expectedAuthority.any { it.isWhitespace() || it.code < 33 || it == '/' }
        ) return false
        if (uri.length !in 24..2048 || !uri.startsWith("content://") ||
            uri.any { it.isWhitespace() || it.code < 32 || it == '\\' } ||
            uri.contains('?') || uri.contains('#')
        ) return false
        val rest = uri.substring("content://".length)
        if (rest.substringBefore('/') != expectedAuthority) return false
        val path = rest.substringAfter('/', "")
        if (!path.startsWith("working/views/") || path.contains("//")) return false
        val segments = path.split('/')
        if (segments.size < 4 || segments.any { it.isEmpty() || it == "." || it == ".." }) {
            return false
        }
        return runCatching { UUID.fromString(segments[2]) }.isSuccess
    }

    private fun validDocumentMime(value: String): Boolean =
        value.length in 3..127 && value.count { it == '/' } == 1 &&
            !value.contains('*') &&
            value.none { it.code < 33 || it.code > 126 } &&
            value.none { it == ';' || it == ',' || it == '\\' || it == '\'' || it == '"' } &&
            value.substringBefore('/').isNotEmpty() && value.substringAfter('/').isNotEmpty()

    private fun validDocumentClass(value: String): Boolean =
        value.length in 1..512 && value.none {
            it.code < 32 || it.code == 127 || it.isWhitespace() || it == '/' || it == '\\'
        }

    private fun validDocumentDisplayName(value: String): Boolean =
        value.length in 1..160 && !value.startsWith('.') &&
            value.none { it == '/' || it == '\\' || it.code < 32 || it.code == 127 }

    fun isProtectedPackage(packageName: String?): Boolean =
        packageName != null &&
            (packageName in PROTECTED_PACKAGES || isFloePackage(packageName))

    /**
     * Attribute a platform semantic interaction event (click/scroll) to its
     * origin.
     *
     * Both programmatic dispatches and real user clicks/scrolls emit
     * TYPE_VIEW_CLICKED / TYPE_VIEW_SCROLLED; only the event's package
     * separates Floe's own window from an external app. Events stamped with
     * Floe's own package are ordinary App UI — the chat streams and
     * autoscrolls while its protected page stays visible after an automatic
     * unlock — and must never fence a run. A genuine user touch on Floe's
     * own Activity is delivered separately by the trusted
     * [com.floe.android.contracts.OwnAppUserPresence] hook. External events
     * keep the conservative existing takeover path.
     */
    fun semanticInteractionOrigin(
        packageName: String?,
        ownAppPackageName: String,
    ): PhoneInteractionOrigin =
        // Only this process's Activity reports through OwnAppUserPresence.
        // Sibling/runtime packages retain the ordinary external event path.
        if (ownAppPackageName.isNotBlank() && packageName == ownAppPackageName) {
            PhoneInteractionOrigin.OWN_APP_SEMANTIC
        } else {
            PhoneInteractionOrigin.EXTERNAL_SEMANTIC
        }

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
     * protected and refuse every node action, including a sensitive input.
     * A user app login screen is not a protected window, but its password
     * fields are redacted and refuse ordinary setText; only an explicit
     * sensitive input may fill one, and its contents are never read back.
     * Screenshots are still refused for any visible password field by
     * [screenshotDenial].
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
            is PhoneControlAction.Focus,
            is PhoneControlAction.Commit,
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
