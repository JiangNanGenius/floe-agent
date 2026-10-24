// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.internal

import com.floe.android.feature.browser.api.BrowserProjectionSnapshot
import com.floe.android.feature.browser.api.BrowserTabRow

/**
 * Pure, scheduler-free presentation fence for the browser panel.
 *
 * The presenter is a MIRROR only: it stores the latest projection for the
 * exact owner binding, and it refuses to project anything that does not
 * belong to this owner (task/workspace/root epoch). It never derives local
 * control truth: the "user controls / continue / close" affordances come
 * exclusively from the native receipt fields, so tab loads, timers,
 * resume/background or view recreation cannot silently return control (the
 * Swift session owns that state and only its projection changes here).
 */
public class BrowserProjectionPresenter(
    private val taskId: String,
    private val workspaceId: String,
    private val rootEpoch: Long,
) {
    /** UI-facing state; only replaced from accepted projections. */
    public data class PanelState(
        val bound: Boolean,
        val projection: BrowserProjectionSnapshot?,
        val panelRequestsUserAttention: Boolean,
        val unboundReason: String?,
    )

    private var state: PanelState = PanelState(
        bound = false,
        projection = null,
        panelRequestsUserAttention = false,
        unboundReason = null,
    )
    private val listeners = mutableListOf<(PanelState) -> Unit>()
    /** Last consumed presentation id; re-presentation of the same request id
     * never re-raises attention (one prompt per request, like the iOS
     * consumePendingPanelRequest route). */
    private var lastAttentionPresentationId: String? = null

    public fun currentState(): PanelState = state

    public fun addListener(listener: (PanelState) -> Unit) {
        listeners += listener
    }

    public fun removeListener(listener: (PanelState) -> Unit) {
        listeners -= listener
    }

    /** Apply one native projection. Foreign-owner or epoch-stale projections
     * are refused: a late JNI reply for a retired binding never repaints. */
    public fun apply(projection: BrowserProjectionSnapshot) {
        if (projection.ownerTaskId != taskId ||
            projection.ownerWorkspaceId != workspaceId ||
            projection.ownerRootEpoch != rootEpoch
        ) {
            state = state.copy(bound = false, projection = null, unboundReason = UNBOUND_FOREIGN)
            publish()
            return
        }
        if (projection.visibleTaskId != null && projection.visibleTaskId != taskId) {
            // Another task is projected: this panel shows only an inert
            // unbound surface (execution keeps running in the other task).
            state = state.copy(bound = false, projection = null, unboundReason = UNBOUND_OTHER_TASK)
            publish()
            return
        }
        val attention = projection.presentationShow == true &&
            projection.presentationId != null &&
            projection.presentationId != lastAttentionPresentationId
        if (attention) lastAttentionPresentationId = projection.presentationId
        state = PanelState(
            bound = true,
            projection = projection,
            panelRequestsUserAttention = attention,
            unboundReason = null,
        )
        publish()
    }

    /** The UI calls this after it has visibly routed the panel-open request. */
    public fun acknowledgeAttention() {
        state = state.copy(panelRequestsUserAttention = false)
        publish()
    }

    public fun unbind(reason: String) {
        state = PanelState(bound = false, projection = null, panelRequestsUserAttention = false, unboundReason = reason)
        publish()
    }

    /**
     * The control-mode banner the sheet renders. All values are projection
     * facts; the returned receiptId is the ONLY value the Continue/close
     * buttons may send back, and only when non-null.
     */
    public data class ControlBanner(
        val userControls: Boolean,
        val returning: Boolean = false,
        val needsContinue: Boolean = false,
        val receiptId: String? = null,
        val errorMessage: String? = null,
        val notified: Boolean = false,
    )

    public fun controlBanner(): ControlBanner {
        val p = state.projection ?: return ControlBanner(userControls = false)
        return ControlBanner(
            userControls = p.isUserControlling,
            returning = p.returningControl,
            needsContinue = p.handoffNeedsContinue,
            receiptId = p.handoffReceiptId,
            errorMessage = p.handoffError,
            notified = p.handoffNotified,
        )
    }

    /** Tab rows are projection-owned; the panel never synthesizes tabs. */
    public fun tabs(): List<BrowserTabRow> = state.projection?.tabs ?: emptyList()

    private fun publish() {
        listeners.toList().forEach { it(state) }
    }

    public companion object {
        public const val UNBOUND_FOREIGN: String = "This browser belongs to a different task binding."
        public const val UNBOUND_OTHER_TASK: String = "Another task's browser is projected."
        public const val UNBOUND_TEMPORARY: String = "Temporary tasks cannot open a durable browser."
    }
}
