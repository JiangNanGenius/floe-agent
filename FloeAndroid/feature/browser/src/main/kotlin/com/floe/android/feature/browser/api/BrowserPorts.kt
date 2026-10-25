// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.api

/**
 * Trusted native authority for the controlled browser, implemented by Main's
 * JNI adapter over the Swift `FloeBrowser` service (BrowserSessionCenter /
 * BrowserToolSurface). This module NEVER decides anything itself: tabs,
 * documents, takeover, URL policy, handoff receipts, preview resources and
 * downloads are all answered by the Swift side through these calls.
 *
 * Threading: every method may be invoked from the UI thread and must be
 * non-blocking (enqueue into the existing bounded bridge). Replies arrive
 * asynchronously through [BrowserServiceCallbacks] on any thread. Identity
 * fields (taskId/workspaceId/rootEpoch) come from the host binding, never
 * from page content or tool JSON.
 */
public interface BrowserServicePort {
    /** Exact owning ordinary task; the browser surface belongs to this task only. */
    public val taskId: String

    /** Workspace this binding is scoped to. */
    public val workspaceId: String

    /** Native root epoch; the Swift center fences stale epochs. */
    public val rootEpoch: Long

    /** Attach the async callback receiver; returns the detach action. */
    public fun attach(callbacks: BrowserServiceCallbacks)

    /**
     * Execute one frozen browser/preview tool call. [toolName] is one of the
     * Swift `BrowserToolSurface.frozenToolNames`; [argsJson] is the typed
     * argument JSON the JNI adapter produced from a trusted UI/tool event.
     * The reply arrives via [BrowserServiceCallbacks.onToolResult] keyed by
     * [requestId]. The Swift side applies the exact owner triple
     * (taskId/workspaceId/rootEpoch); this call carries no owner choice.
     */
    public fun submitTool(requestId: String, toolName: String, argsJson: String)

    /** Execute one typed protocol command (JSON of Swift `BrowserCommand`). */
    public fun submitCommand(requestId: String, commandJson: String)

    /**
     * Push lifecycle ingress: a `BrowserRendererLifecycleEvent` JSON emitted
     * by [BrowserWebViewGateway]. Trusted platform facts only; Swift fences
     * unknown tabs and stale sessions. Fire-and-forget.
     */
    public fun ingestLifecycle(eventJson: String)

    /**
     * Ask Swift about a popup/new-window request. Must not block the caller:
     * the decision arrives via [BrowserServiceCallbacks.onPopupDecision].
     */
    public fun requestPopupDecision(requestId: String, tabId: String, url: String)

    /**
     * Forward a WebView DownloadListener fact to the Swift download
     * coordinator. Swift fetches, caps, hashes and stages/commits the file
     * itself; this module performs NO network IO and NO file writes.
     */
    public fun requestDownload(requestId: String, queryJson: String)

    /**
     * Bind/unbind the visible projection to this task (presentation only).
     * Unbinding never stops another task's sessions. A rebind is the trusted
     * "human reopened the task" signal on the Swift side.
     */
    public fun bindVisible()

    public fun unbindVisible()

    /** Address-bar text change (Swift stores the truth; this is UI echo). */
    public fun setAddressText(text: String)

    public fun setEditingAddress(editing: Boolean)

    /** Commit the address bar entry; Swift applies URL policy + reload rules. */
    public fun navigateFromAddressBar()

    /**
     * Atomic commit carrying the exact draft: the text rides in the ONE
     * owned navigate op and the Swift session applies it, clears the editing
     * flag and captures + policy-validates the navigation target BEFORE its
     * first suspension, so a late keystroke echo can never change what this
     * commit navigates to. The default keeps legacy hosts behaviorally
     * identical to the old UI sequence (clear editing, then commit); only
     * hosts whose native commit op carries text override it.
     */
    public fun navigateFromAddressBar(draft: String) {
        setEditingAddress(false)
        navigateFromAddressBar()
    }

    /** Panel Retry: Swift reloads this conversation's active tab. */
    public fun requestReload()

    /** Panel history arrows: Swift dispatches the exact owning session. */
    public fun goBackTab()

    public fun goForwardTab()

    /** Tab-chrome operations, typed (the JNI adapter encodes tool JSON). */
    public fun performPanelOperation(operation: BrowserPanelOperation)

    /**
     * User "take control" button. The Swift center mints/maintains the
     * durable handoff receipt; Kotlin stores no control Boolean.
     */
    public fun takeControl()

    /**
     * "Continue/close" callbacks MUST carry the native receipt id from
     * [BrowserServiceCallbacks.onProjection]; a mismatched id is refused by
     * Swift and changes nothing. [continueTask] maps to the original
     * returnToAgent(continueTask:) semantics.
     */
    public fun returnToAgent(receiptId: String, continueTask: Boolean)

    /** Read-and-clear this task's pending panel request (explicit selection). */
    public fun consumePendingPanelRequest()

    /** Close THIS task's panel via Swift (refused while the user controls). */
    public fun dismissPanel()
}

/** Tab-chrome operations bound to this panel's exact owning task. */
public sealed interface BrowserPanelOperation {
    public data object CreateTab : BrowserPanelOperation
    public data class Activate(val tabId: String) : BrowserPanelOperation
    public data class Close(val tabId: String) : BrowserPanelOperation
}

/** Async replies from the Swift authority. Callbacks must be safe on any thread. */
public interface BrowserServiceCallbacks {
    /** `BrowserResult` JSON for a submitCommand / tool invocation. */
    public fun onCommandResult(requestId: String, resultJson: String)

    /** Tool envelope: `{ok, summary, error?, requiresUserAction?}` from Swift. */
    public fun onToolResult(requestId: String, toolName: String, ok: Boolean, summaryJson: String, requiresUserAction: Boolean, errorCode: String?)

    /** Popup verdict: `openInNewTab` (with Swift-minted tabId) or `blocked`. */
    public fun onPopupDecision(requestId: String, decisionJson: String)

    /** Download outcome facts (ticket/commit/failure), UI notification only. */
    public fun onDownloadSignal(signalJson: String)

    /**
     * The ONLY projection channel: Swift `BrowserProjection` JSON after every
     * projection-bearing transition, in order. The presenter keeps no
     * parallel truth.
     */
    public fun onProjection(projectionJson: String)
}

/**
 * Swift-owned preview adjudication for the loopback transport. The Kotlin
 * transport forwards raw bounded header blocks here and streams ONLY the
 * bytes the verdict admits; it has no path or authorization logic. All
 * methods may block the calling transport thread (it is a dedicated IO
 * thread, never the UI thread) and must resolve within the Swift budgets.
 */
public interface BrowserPreviewAuthority {
    /**
     * Adjudicate one request. [serverId] is the Swift-issued lease UUID from
     * `BrowserPreviewOutcome`; an unknown/stopped lease returns an honest 404
     * verdict. Field names mirror Swift `BrowserPreviewVerdict`.
     */
    public fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication

    /**
     * Next bounded slice of an admitted body. [offset] counts from the start
     * of the admitted slice (the verdict chunk already covers bytes below
     * chunkCount). Empty result = done/retired.
     */
    public fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int): ByteArray
}

public data class PreviewAdjudication(
    val statusLine: String,
    val headers: List<Pair<String, String>>,
    val bodyLength: Int,
    val bodyStart: Int,
    val chunk: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        other is PreviewAdjudication && statusLine == other.statusLine &&
            headers == other.headers && bodyLength == other.bodyLength &&
            bodyStart == other.bodyStart && chunk.contentEquals(other.chunk)

    override fun hashCode(): Int =
        (statusLine.hashCode() * 31 + headers.hashCode()) * 31 + bodyLength * 7 + chunk.size
}

/**
 * THE ONLY permission hook this module knows about. Main's App host wires it
 * to the ALREADY-EXISTING Application-owned `LocalNetworkAccessBroker`
 * (IntegrationsHostController.runExplicitAction; RuntimeHostComposition's
 * single installed LocalNetworkPermissionEffect). This module NEVER stores,
 * launches or re-derives permission state, never adds Manifest entries, and
 * never prompts automatically from page content, a load, a timer or an idle
 * background transition: the gate is consulted exactly once per explicit,
 * user- or tool-initiated preview start on API37+ targets, before the
 * loopback listener binds. Ordinary loopback 127.0.0.1 + token + native
 * policy is unchanged; whether an API37 denied-LAN grant affects loopback is
 * an open device gate, so the honest mapping below simply FAILS the start
 * typed (the grant question belongs to Main's App controller, never here).
 */
public interface LoopbackBindPermissionGate {
    public enum class Outcome {
        /** Broker answered: allowed (API<37 NotRequired, or granted). */
        allowed,

        /** API>=37 dialog denied for this explicit action: the preview start
         * must fail typed `local_network_permission_denied`; denial is NOT
         * auth failure and the task keeps its local work. */
        denied,

        /** No broker is wired (older hosts/qualification): proceed; the
         * loopback bind either succeeds or fails honestly at the socket. */
        unwired,
    }

    /**
     * @param endpointDescription exact `127.0.0.1:<os-assigned>`-style text
     *        WITHOUT the token (never leak the per-server secret into UI).
     * @param isCurrent owner/epoch/currentness fence supplied by Main.
     * Non-blocking; completion may arrive on any thread.
     */
    public fun ensureBindAllowed(
        endpointDescription: String,
        isCurrent: () -> Boolean,
        completion: (Outcome) -> Unit,
    )
}

/** Swift-owned download sink (Main wires the staged/verified workspace save). */
public interface BrowserDownloadSinkPort {
    /** Opaque staging handle for the admitted ticket. */
    public fun open(ticketJson: String): String

    public fun append(handle: String, bytes: ByteArray)

    /** Verified staged commit at the owner's destination; receipt JSON back. */
    public fun commit(handle: String, sha256: String, expectedBytes: Int): String

    public fun discard(handle: String)
}
