// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.api

/**
 * Typed mirror of the Swift `BrowserRendererTabState`. Produced by the local
 * WebView surface; consumed by Main's JNI adapter as renderer STATE facts.
 * These are untrusted-page-adjacent getters: they describe what the surface
 * shows; they never authorize anything (Swift fences navigation, documents
 * and origins before anything acts on them).
 */
public data class RendererTabState(
    val url: String?,
    val title: String?,
    val isLoading: Boolean,
    val viewportWidth: Double,
    val viewportHeight: Double,
    val scrollX: Double,
    val scrollY: Double,
)

public data class RendererScreenshot(
    val jpeg: ByteArray,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val state: RendererTabState,
) {
    override fun equals(other: Any?): Boolean =
        other is RendererScreenshot && pixelWidth == other.pixelWidth &&
            pixelHeight == other.pixelHeight && jpeg.contentEquals(other.jpeg) &&
            state == other.state

    override fun hashCode(): Int = jpeg.size * 31 + pixelWidth * 7 + pixelHeight
}

/**
 * The dumb android.webkit surface driven by the Swift session. Main's JNI
 * proxy implements the Swift `BrowserRenderer` protocol by calling this
 * gateway; every asynchronous completion must fire exactly once (late or
 * duplicate replies are discarded by the Swift deadline fence, never
 * re-dispatched).
 *
 * HARD rules the implementation must honor (see BrowserWebViewRenderer):
 *  - NEVER `addJavascriptInterface`: the page has no bridge into the app.
 *  - Every `evaluate` expression arrives pre-built and JSON-escaped by Swift
 *    from whitelisted admitted actions; the gateway may not compose actuator
 *    scripts from page data.
 *  - `destroyTab` is only ever called for Swift-retired tabs; Compose view
 *    recreation never destroys a tab or returns control.
 */
public interface BrowserWebViewGateway {
    /** Register a Swift-minted tab. The platform surface may arrive later
     * (popups adopt their WebView when the decision callback returns). */
    public fun createTab(tabId: String, probeSource: String)

    public fun destroyTab(tabId: String)
    public fun navigate(tabId: String, url: String)
    public fun goBack(tabId: String)
    public fun goForward(tabId: String)
    public fun reload(tabId: String)
    public fun stopLoading(tabId: String)

    /** Current surface facts for one tab, or null when the tab is gone. */
    public fun state(tabId: String): RendererTabState?

    /** evaluateJavascript wrapper; reply fires once with the JSON string. */
    public fun evaluate(tabId: String, expression: String, timeoutMs: Int, reply: (String?) -> Unit)

    /** Viewport draw → JPEG bytes; reply fires once (null on unavailability). */
    public fun captureScreenshot(tabId: String, reply: (RendererScreenshot?) -> Unit)

    /** Adopt a popup-produced WebView instance into a Swift-minted tab. */
    public fun adoptPopupSurface(tabId: String, surfaceToken: Long)

    /** Release every platform resource for this owner session. */
    public fun release()
}

/**
 * Typed projection consumed by [com.floe.android.feature.browser.internal.BrowserProjectionPresenter].
 * Main's JNI adapter decodes the Swift `BrowserProjection` JSON into this
 * shape; field names mirror the Swift keys 1:1. The Kotlin side keeps NO
 * parallel browser truth: no local control Boolean, no local tab list, no
 * local receipt state.
 */
public data class BrowserProjectionSnapshot(
    val ownerTaskId: String,
    val ownerWorkspaceId: String,
    val ownerRootEpoch: Long,
    val visibleTaskId: String?,
    val presentationShow: Boolean?,
    val presentationId: String?,
    /** Durable handoff receipt id for the visible task (null = no receipt). */
    val handoffReceiptId: String?,
    val handoffReturning: Boolean,
    val handoffNeedsContinue: Boolean,
    val handoffNotified: Boolean,
    val handoffError: String?,
    val returningControl: Boolean,
    val surfaceStateKind: String, // unbound|ready|loading|failed|needsUser
    val surfaceStateDetail: String?,
    val tabs: List<BrowserTabRow>,
    val activeTabId: String?,
    val isUserControlling: Boolean,
    val addressText: String,
    val isEditingAddress: Boolean,
    val technicalAddress: String?,
    val isDisplayingLocalPreview: Boolean,
)

public data class BrowserTabRow(
    val id: String,
    val url: String,
    val title: String,
    val isActive: Boolean,
)

/**
 * Honest capability boundaries of the Android platform surface (D4 / task
 * contract). The UI renders these as typed limitations; nothing here is a
 * fake success path.
 */
public object BrowserPlatformLimitations {
    /** android.webkit uses the process-global CookieManager storage:
     * login state persists across tabs and sessions (preserved, real
     * cookies) but per-profile/incognito isolation is NOT provideable
     * without a supported isolation mechanism, which minSdk 28 plain
     * WebView does not offer. Never promise more. */
    public const val EPHEMERAL_PROFILES_SUPPORTED: Boolean = false

    /** On-device OCR (Vision) is not available on Android today:
     * browser.screenshot returns an empty visualTextRegions set and
     * browser.clickVisualText answers the original "absent or stale"
     * refusal. No recognizer is substituted. */
    public const val VISUAL_TEXT_OCR_SUPPORTED: Boolean = false

    /** Document-start script injection depends on the WebView build; the
     * gateway re-injects at every page commit and the probe protocol
     * tolerates the race with its degraded honest snapshot. */
    public const val DOCUMENT_START_INJECTION_GUARANTEED: Boolean = false
}
