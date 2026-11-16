// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.app.Activity
import java.util.UUID

/** Exact waiting request. It contains no model input text or authority. */
data class DeviceApprovalIdentity(
    val taskID: UUID, val runID: UUID, val nativeEpoch: Long, val hostGeneration: Long,
    val callID: String, val generation: String, val descriptorIdentity: String,
)

data class DeviceApprovalAction(
    val observationId: String, val nodeRef: String, val action: String,
    val direction: String?, val inputKind: String?,
)

data class DeviceApprovalTarget(
    val packageName: String, val className: String, val label: String,
    val left: Int, val top: Int, val right: Int, val bottom: Int, val digest: String,
) {
    override fun toString(): String = "DeviceApprovalTarget(redacted)"
}

interface DeviceApprovalOverlayCallbacks {
    fun onVisibilityChanged(identity: DeviceApprovalIdentity, presentationId: String, visible: Boolean)
    fun onDecision(identity: DeviceApprovalIdentity, presentationId: String, allow: Boolean)
}

/**
 * Channel-neutral lifecycle seam for an OPTIONAL platform extension that is
 * owned by the Application (never by a view, sheet or composition).
 *
 * The common App host holds this interface only. The FULL flavour supplies a
 * real implementation (phone/ADB/Root settings presentation and the trusted
 * platform-tool pump); the PLAY flavour supplies an inert instance and must not
 * import any Full class, resource, tool name or backend module.
 *
 * Contract:
 *  - [onHostStarted] runs exactly once after the Application-owned
 *    [RuntimeHost] is created; it must stay data-only (no native/disk/device
 *    work on the caller thread).
 *  - [onOwnedStoreReady] runs for EVERY accepted native root generation. The
 *    extension binds only to the exact live [epoch] it is given and must stop
 *    the previous generation through its own drain before binding a new one.
 *  - [prepareForRootStop] runs BEFORE the native root is retired and returns
 *    false when real owned work could not drain; a refusal keeps the old
 *    generation honestly pending (never a fake clean stop).
 *  - [onRootStopped] runs after a retired generation; late callbacks must be
 *    fenced and an extension must not retire a newer live generation from a
 *    stale notification.
 *  - [onActivityResumed]/[onActivityPaused] are the ONLY Activity hooks; they
 *    may reconcile real status with bounded cancellable work, never start an
 *    Agent run and never keep a PiP/keepalive surface.
 *  - [close] is terminal for the process host.
 */
interface RuntimePlatformExtension {
    /** Callback lease belongs to the waiting holder; the overlay grants nothing. */
    fun presentDeviceApproval(identity: DeviceApprovalIdentity, callbacks: DeviceApprovalOverlayCallbacks): Boolean = false
    fun setDeviceApprovalTarget(identity: DeviceApprovalIdentity, presentationId: String,
                                action: DeviceApprovalAction?, target: DeviceApprovalTarget?, enabled: Boolean) = Unit
    fun dismissDeviceApproval(identity: DeviceApprovalIdentity) = Unit
    suspend fun readDeviceApprovalTarget(identity: DeviceApprovalIdentity, presentationId: String, action: DeviceApprovalAction,
                                         stillCurrent: () -> Boolean): DeviceApprovalTarget? = null

    fun onHostStarted(host: RuntimeHost) = Unit

    fun onOwnedStoreReady(epoch: Long) = Unit

    suspend fun prepareForRootStop(): Boolean = true

    fun onRootStopped() = Unit

    fun onActivityResumed(activity: Activity) = Unit

    fun onActivityPaused() = Unit

    /** Notification only: authoritative holder activity changed, including in background. */
    fun onRunActivityChanged() = Unit

    /** A user requested Stop for this exact live-generation run. This is not a
     * claim that its durable cancellation has already completed. */
    fun onRunStopRequested(epoch: Long, taskID: UUID, runID: UUID) = Unit

    /** Presentation only, from an admitted native workspace grant, never tool arguments. */
    fun onBackgroundWorkStarted(epoch: Long, taskID: UUID, runID: UUID) = Unit

    fun close() = Unit
}

/** Inert default for pure controller fixtures and the PLAY channel. */
internal object EmptyRuntimePlatformExtension : RuntimePlatformExtension
