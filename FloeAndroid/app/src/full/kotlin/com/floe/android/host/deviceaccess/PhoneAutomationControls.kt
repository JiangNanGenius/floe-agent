// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.StateSet
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import com.floe.android.FloeThemeStore
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.design.FloeThemeMode
import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.phonecontrol.PhoneControlTouchDiagnostic
import com.floe.android.host.DeviceApprovalIdentity
import com.floe.android.host.DeviceApprovalAction
import com.floe.android.host.DeviceApprovalTarget
import com.floe.android.host.DeviceApprovalOverlayCallbacks
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** One cancellable pending card; no timer and no approval authority. */
internal class DeviceApprovalRegistration {
    data class Entry(val identity: DeviceApprovalIdentity, val callbacks: DeviceApprovalOverlayCallbacks)
    private var value: Entry? = null
    @Synchronized fun register(entry: Entry) { value = entry }
    @Synchronized fun current(): Entry? = value
    @Synchronized fun isCurrent(entry: Entry): Boolean = value === entry
    @Synchronized fun cancelEntry(entry: Entry): Boolean {
        if (value !== entry) return false
        value = null
        return true
    }
    @Synchronized fun cancel(identity: DeviceApprovalIdentity): Entry? {
        val old = value?.takeIf { it.identity == identity } ?: return null
        value = null
        return old
    }
    @Synchronized fun cancelOwner(owner: PhoneControlOwner) {
        val current = value?.identity ?: return
        if (current.taskID == owner.taskID && current.runID == owner.runID) value = null
    }
    @Synchronized fun clear() { value = null }
}

/**
 * Process-local, revocable controls plus a compact, truthful floating status.
 *
 * Presentation is a 48dp draggable bubble. Tapping it opens a narrow panel
 * with the real task/action/result and the existing pause/resume and takeover
 * actions; four seconds without a user touch collapses it again. Collapsing
 * is presentation only: it never pauses, resumes, takes over, executes or
 * changes permissions. Only a real RUNNING operation animates; waiting and
 * paused states stay static. Consecutive screen operations reuse one window;
 * background work or the end of screen control removes the bubble.
 *
 * The status is fed from the real claimed platform tool lifecycle (started ->
 * actual outcome) and from the typed background document-view verification.
 * It never carries node text, typed values, credentials, a fake click trail or
 * a claim that an accepted launch was rendered. Only the latest operation is
 * retained (bounded fields, no event list), and every update is fenced by the
 * exact owner/token and cleared when the owner ends or the user pauses/stops.
 *
 * Notifications and overlays cannot revive a past run: [clear] removes both,
 * and a stale receiver token is ignored.
 */
internal data class OverlayTakeoverBinding(
    val epoch: Long,
    val ownerRevision: Long,
    val streamStamp: Map<String, Long>,
) {
    fun matches(epoch: Long?, revision: Long, stream: Map<String, Long>, closed: Boolean): Boolean =
        !closed && epoch == this.epoch && revision == ownerRevision && stream == streamStamp
}

internal class PhoneAutomationControls(
    private val context: Context,
    private val act: (PhoneControlOwner, Action) -> Unit,
    private val captureTakeover: (PhoneControlOwner) -> OverlayTakeoverBinding?,
    private val takeOver: (PhoneControlOwner, OverlayTakeoverBinding, Boolean) -> Unit,
    private val canPresent: (PhoneControlOwner) -> Boolean,
    private val ownerStillLive: (PhoneControlOwner) -> Boolean,
    private val approvalStillCurrent: (DeviceApprovalIdentity) -> Boolean,
) {
    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val windows = context.getSystemService(WindowManager::class.java)
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val themeStore by lazy { FloeThemeStore(context) }
    private var owner: PhoneControlOwner? = null
    private var token = UUID.randomUUID().toString()
    private var takeoverBinding: OverlayTakeoverBinding? = null
    private var deferredClear: Runnable? = null
    enum class Action { PAUSE, RESUME }

    private var bubble: FrameLayout? = null
    private var bubbleProgress: ProgressBar? = null
    private var bubbleStateDot: View? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var bubbleX = Int.MIN_VALUE
    private var bubbleY = Int.MIN_VALUE
    private var dragStartX = 0
    private var dragStartY = 0
    private var dragDownRawX = 0f
    private var dragDownRawY = 0f
    private var dragging = false

    private var panel: LinearLayout? = null
    private var panelTitle: TextView? = null
    private var panelStatus: TextView? = null
    private var panelPause: Button? = null
    private var panelTakeOver: Button? = null
    private var panelParams: WindowManager.LayoutParams? = null
    private var panelWidth = 0
    private var panelHeight = 0
    private var expanded = false
    private var collapseRunnable: Runnable? = null
    private var appliedDark: Boolean? = null
    private var lastDotColor: Int? = null
    private var lastPanelTitle: String? = null
    private var lastPanelStatus: String? = null
    private var lastPanelPaused: Boolean? = null
    private var approvalIdentity: DeviceApprovalIdentity? = null
    private var approvalCallbacks: DeviceApprovalOverlayCallbacks? = null
    private var approvalVisible = false
    private var approvalPresentationId: String? = null
    private var approvalAction: DeviceApprovalAction? = null
    private var approvalTarget: DeviceApprovalTarget? = null
    private var approvalEnabled = false
    private var approvalFailed = false
    private val approvalRegistration = DeviceApprovalRegistration()
    private var approvalText: TextView? = null
    private var approvalAllow: Button? = null
    private var approvalDeny: Button? = null
    private var configCallbacksRegistered = false

    private val configCallbacks = object : ComponentCallbacks {
        override fun onConfigurationChanged(newConfig: Configuration) {
            main.post { runCatching { clampAfterConfigurationChange() } }
        }

        override fun onLowMemory() = Unit
    }

    private var paused = false
    private var waitingForUser = false
    private var title = ""
    private var showOverlay = false
    private var operation: PhoneAutomationOperation? = null
    private var operationOwner: PhoneControlOwner? = null
    /** A start that arrived before [show] bound the same owner. RAM-only and
     * replaced by the next start/finish; never a history buffer. */
    private data class PendingOperation(val owner: PhoneControlOwner, val label: String, val id: String)
    private var pendingOperation: PendingOperation? = null
    private var activeOperationID: String? = null
    private var clearAfterOperation = false
    private var retireFinishedRunnable: Runnable? = null

    /** Accepts a cancellable pending request; true means queued, not displayed. */
    fun presentApproval(identity: DeviceApprovalIdentity, callbacks: DeviceApprovalOverlayCallbacks): Boolean {
        val entry = DeviceApprovalRegistration.Entry(identity, callbacks)
        approvalRegistration.register(entry)
        if (main.post { tryPresentApproval(entry) }) return true
        approvalRegistration.cancelEntry(entry)
        return false
    }

    private fun tryPresentApproval(entry: DeviceApprovalRegistration.Entry) {
        if (!approvalRegistration.isCurrent(entry)) return
        val identity = entry.identity
        val expected = PhoneControlOwner(identity.taskID, identity.runID)
        if (approvalIdentity != null &&
            (approvalIdentity != identity || approvalCallbacks !== entry.callbacks)) {
            retireApproval()
            if (expanded) collapsePanel()
        }
        if (!approvalStillCurrent(identity)) {
            if (approvalRegistration.cancelEntry(entry)) {
                if (approvalIdentity == identity && approvalCallbacks === entry.callbacks) {
                    retireApproval()
                }
                entry.callbacks.onVisibilityChanged(identity, "", false)
            }
            return
        }
        if (owner != expected || !canPresent(expected) || !ownerStillLive(expected) ||
            !waitingForUser || paused || !showOverlay || !Settings.canDrawOverlays(context) || bubble == null) return
        if (approvalIdentity == identity && approvalCallbacks === entry.callbacks) return
        if (!approvalRegistration.isCurrent(entry)) return
        retireApproval()
        approvalIdentity = identity
        approvalCallbacks = entry.callbacks
        if (panel != null && expanded) {
            collapsePanel()
            expandPanel()
        }
    }

    /**
     * The exact pending approval card (`run/call`) registered for this owner,
     * if any. Presentation bookkeeping only: it grants nothing and is used to
     * bind a Stop/Takeover projection to the call it actually retired.
     */
    fun approvalKey(owner: PhoneControlOwner): String? {
        val identity = approvalRegistration.current()?.identity ?: return null
        if (identity.taskID != owner.taskID || identity.runID != owner.runID) return null
        return "${identity.runID}/${identity.callID}"
    }

    fun hasApprovalFor(owner: PhoneControlOwner): Boolean = approvalKey(owner) != null

    fun isApprovalVisible(identity: DeviceApprovalIdentity, presentationId: String): Boolean =
        Looper.myLooper() == main.looper && approvalIdentity == identity && approvalVisible &&
            approvalPresentationId == presentationId &&
            expanded && panel?.isAttachedToWindow == true && waitingForUser && !paused && showOverlay &&
            owner == PhoneControlOwner(identity.taskID, identity.runID) &&
            owner?.let { canPresent(it) && ownerStillLive(it) } == true && approvalStillCurrent(identity) &&
            approvalRegistration.current()?.let { it.identity == identity && it.callbacks === approvalCallbacks } == true &&
            Settings.canDrawOverlays(context)

    fun setApprovalTarget(identity: DeviceApprovalIdentity, presentationId: String,
                          action: DeviceApprovalAction?, target: DeviceApprovalTarget?, enabled: Boolean) {
        if (Looper.myLooper() != main.looper) { main.post { setApprovalTarget(identity, presentationId, action, target, enabled) }; return }
        if (!isApprovalVisible(identity, presentationId)) return
        approvalAction = action
        approvalTarget = target
        approvalFailed = target == null
        approvalEnabled = enabled && target != null && action?.action == "click"
        updateApprovalContent()
    }

    fun dismissApproval(identity: DeviceApprovalIdentity) {
        val cancelled = approvalRegistration.cancel(identity) ?: return
        val dismiss = {
            if (approvalIdentity == identity && approvalCallbacks === cancelled.callbacks) {
                retireApproval()
                if (expanded) { collapsePanel(); expandPanel() }
            }
        }
        if (Looper.myLooper() == main.looper) dismiss() else main.post { dismiss() }
    }

    private fun retireApproval() {
        val old = approvalIdentity
        val callback = approvalCallbacks
        val wasVisible = approvalVisible
        val presentationId = approvalPresentationId
        approvalIdentity = null
        approvalCallbacks = null
        approvalVisible = false
        approvalPresentationId = null
        approvalAction = null
        approvalTarget = null
        approvalEnabled = false
        approvalFailed = false
        if (wasVisible && old != null && presentationId != null) callback?.onVisibilityChanged(old, presentationId, false)
    }

    fun show(owner: PhoneControlOwner, title: String, overlay: Boolean, paused: Boolean = false,
             waitingForUser: Boolean = false) {
        main.post {
            if (!canPresent(owner)) {
                clear(expectedOwner = owner, retainApprovalRegistration = ownerStillLive(owner))
                return@post
            }
            val nextTakeoverBinding = captureTakeover(owner)
            if (this.owner != owner && operationOwner != owner) {
                this.operation = null
                this.operationOwner = null
                activeOperationID = null
            }
            if (this.paused != paused) {
                this.operation = null
                this.operationOwner = null
                activeOperationID = null
            }
            if (this.owner != owner || this.paused != paused || takeoverBinding != nextTakeoverBinding) {
                cancelRetireFinished()
                clearAfterOperation = false
                removeOverlay()
                token = UUID.randomUUID().toString()
                takeoverBinding = nextTakeoverBinding
            }
            deferredClear?.let(main::removeCallbacks)
            deferredClear = null
            this.owner = owner
            this.paused = paused
            this.waitingForUser = waitingForUser
            if (!waitingForUser || paused) retireApproval()
            this.title = PhoneAutomationStatusText.bounded(title, 48)
            showOverlay = overlay
            // The trusted pump calls start immediately before the first
            // device call, while the owner may not have been rendered yet.
            // Adopt that bounded start once it belongs to this exact owner.
            if (!paused) {
                pendingOperation?.takeIf { it.owner == owner }?.let { pending ->
                    operation = PhoneAutomationStatusText.operation(
                        pending.label, PhoneAutomationOperationState.RUNNING)
                    operationOwner = owner
                    activeOperationID = pending.id
                    pendingOperation = null
                }
            } else {
                pendingOperation = null
            }
            PhoneAutomationRelay.controls = this
            render()
            approvalRegistration.current()?.let(::tryPresentApproval)
            if (paused || waitingForUser) {
                cancelRetireFinished()
            } else if (retireFinishedRunnable == null && operationOwner == owner) {
                scheduleRetireFinished(owner)
            }
        }
    }

    /** A real claimed device operation started. UI-only; no authority. */
    fun operationStarted(owner: PhoneControlOwner, label: String, operationID: String) {
        main.post {
            if (!ownerStillLive(owner)) return@post
            if (paused) return@post
            if (this.owner == null) {
                cancelRetireFinished()
                pendingOperation = PendingOperation(owner, PhoneAutomationStatusText.bounded(label, 32), operationID)
                return@post
            }
            if (this.owner != owner) return@post
            cancelRetireFinished()
            clearAfterOperation = false
            operation = PhoneAutomationStatusText.operation(
                label, PhoneAutomationOperationState.RUNNING)
            operationOwner = owner
            activeOperationID = operationID
            render()
        }
    }

    /** The same task moved on to real non-screen work. Do not disturb an
     * in-flight screen operation; retire its window at that operation's end. */
    fun backgroundWorkStarted(owner: PhoneControlOwner) {
        main.post {
            if (this.owner == owner && (paused || waitingForUser)) return@post
            if (this.owner == owner && operation?.state == PhoneAutomationOperationState.RUNNING) {
                clearAfterOperation = true
            } else {
                clear(expectedOwner = owner)
            }
        }
    }

    /** The actual settled outcome (or an honest unknown/cancel). */
    fun operationFinished(
        owner: PhoneControlOwner,
        label: String,
        state: PhoneAutomationOperationState,
        note: String? = null,
        operationID: String,
    ) {
        main.post {
            if (!ownerStillLive(owner)) return@post
            if (this.owner == null) {
                val pending = pendingOperation ?: return@post
                if (pending.owner != owner || pending.id != operationID) return@post
                pendingOperation = null
                operation = PhoneAutomationStatusText.operation(
                    label,
                    if (paused) PhoneAutomationOperationState.CANCELLED else state,
                    note,
                )
                operationOwner = owner
                scheduleRetireFinished(owner)
                return@post
            }
            if (this.owner != owner || activeOperationID != operationID) return@post
            activeOperationID = null
            operation = PhoneAutomationStatusText.operation(
                label,
                if (paused) PhoneAutomationOperationState.CANCELLED else state,
                note,
            )
            operationOwner = owner
            if (clearAfterOperation && !paused && !waitingForUser) {
                clear(expectedOwner = owner)
            } else {
                render()
                scheduleRetireFinished(owner)
            }
        }
    }

    /** Keep a settled result briefly between consecutive actions, but do not
     * leave a stale bubble over other apps while the agent is thinking. */
    private fun scheduleRetireFinished(expectedOwner: PhoneControlOwner) {
        cancelRetireFinished()
        val settled = operation ?: return
        if (settled.state !in setOf(PhoneAutomationOperationState.DONE,
                PhoneAutomationOperationState.FAILED, PhoneAutomationOperationState.UNKNOWN,
                PhoneAutomationOperationState.WAITING)) return
        val runnable = Runnable {
            retireFinishedRunnable = null
            if (operationOwner != expectedOwner || operation !== settled || paused || waitingForUser) return@Runnable
            operation = null
            operationOwner = null
            if (owner == expectedOwner) render()
        }
        retireFinishedRunnable = runnable
        main.postDelayed(runnable, FINISHED_BUBBLE_DELAY_MS)
    }

    private fun cancelRetireFinished() {
        retireFinishedRunnable?.let { main.removeCallbacks(it) }
        retireFinishedRunnable = null
    }

    internal fun receive(receivedToken: String?, action: String?) {
        val deliver = deliver@{
            if (owner == null || token != receivedToken) return@deliver
            val current = owner ?: return@deliver
            // A physical tap can fence Accessibility before this callback.
            // The pre-bound token still identifies the exact interrupted run.
            if (action == "stop" || (action == "pause" && !paused)) {
                val binding = takeoverBinding
                if (binding != null) takeOver(current, binding, action == "stop")
                else android.widget.Toast.makeText(context, R.string.phone_automation_control_changed,
                    android.widget.Toast.LENGTH_SHORT).show()
                return@deliver
            }
            if (!canPresent(current)) {
                clear(expectedOwner = current, retainApprovalRegistration = ownerStillLive(current))
                return@deliver
            }
            if (action == "resume" && paused) act(current, Action.RESUME)
        }
        if (Looper.myLooper() == main.looper) deliver() else main.post { deliver() }
    }

    private fun statusLine(): String {
        if (paused) return context.getString(R.string.phone_automation_paused)
        if (waitingForUser) return context.getString(R.string.device_automation_state_waiting)
        val current = operation
            ?: return context.getString(R.string.device_automation_status_active)
        val state = when (current.state) {
            PhoneAutomationOperationState.RUNNING -> R.string.device_automation_state_running
            PhoneAutomationOperationState.DONE -> R.string.device_automation_state_done
            PhoneAutomationOperationState.WAITING -> R.string.device_automation_state_waiting
            PhoneAutomationOperationState.FAILED -> R.string.device_automation_state_failed
            PhoneAutomationOperationState.UNKNOWN -> R.string.device_automation_state_unknown
            PhoneAutomationOperationState.CANCELLED -> R.string.device_automation_state_cancelled
        }
        val stateText = context.getString(state)
        return if (current.note == null) {
            context.getString(R.string.device_automation_status_format,
                current.label, stateText)
        } else {
            context.getString(R.string.device_automation_status_note_format,
                current.label, stateText, current.note.orEmpty())
        }
    }

    private fun render() {
        val current = owner ?: return
        if (!canPresent(current)) {
            clear(expectedOwner = current, retainApprovalRegistration = ownerStillLive(current))
            return
        }
        runCatching { renderNotification() }
        runCatching { renderOverlay() }
    }

    private fun renderNotification() {
        notifications.createNotificationChannel(NotificationChannel(CHANNEL,
            context.getString(R.string.phone_automation_title), NotificationManager.IMPORTANCE_DEFAULT))
        val current = owner ?: return
        val launch = PendingIntent.getActivity(context, 9481,
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .setData(Uri.parse("floe://task/${current.taskID}")),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        fun action(name: String, request: Int) = PendingIntent.getBroadcast(context, request,
            Intent(context, PhoneAutomationReceiver::class.java).setData(Uri.parse("floe-control://$token/$name"))
                .putExtra("token", token).putExtra("action", name),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val status = statusLine()
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(context.getString(R.string.phone_automation_title))
            .setContentText(status.replace('\n', ' ')).setContentIntent(launch).setOngoing(true).setOnlyAlertOnce(true)
            .setSubText(title.takeIf { it.isNotBlank() })
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0, context.getString(if (paused) R.string.phone_automation_resume else R.string.phone_automation_pause),
                action(if (paused) "resume" else "pause", if (paused) 9484 else 9483))
            .addAction(0, context.getString(R.string.phone_automation_stop), action("stop", 9482))
        notifications.notify(NOTIFICATION, builder.build())
    }

    private fun renderOverlay() {
        val current = owner
        if (current == null) {
            removeOverlay()
            return
        }
        if (!canPresent(current)) {
            clear(expectedOwner = current, retainApprovalRegistration = ownerStillLive(current))
            return
        }
        if (!showOverlay || !Settings.canDrawOverlays(context) ||
            !PhoneAutomationStatusText.showsOverlay(paused, waitingForUser, operation?.state)) {
            removeOverlay()
            return
        }
        val p = palette()
        val currentBubble = ensureBubble(p) ?: return
        if (appliedDark != p.dark) {
            applyBubbleAppearance(currentBubble, p)
            panel?.let { applyPanelAppearance(it, p) }
            appliedDark = p.dark
        }
        updateBubbleState(p)
        if (expanded) {
            val currentPanel = ensurePanel(p) ?: return
            val contentChanged = updatePanelContent()
            if (contentChanged) {
                panelHeight = measurePanel(currentPanel, panelWidth)
            }
            positionPanel()
        }
    }

    // ------------------------------------------------------------- bubble

    private fun ensureBubble(palette: Palette): FrameLayout? {
        bubble?.let { return it }
        if (bubbleX == Int.MIN_VALUE || bubbleY == Int.MIN_VALUE) {
            val (screenWidth, screenHeight) = screenBounds()
            bubbleX = clampBubbleX(screenWidth - dp(48) - dp(16))
            bubbleY = clampBubbleY((screenHeight - dp(48)) / 2)
        } else {
            bubbleX = clampBubbleX(bubbleX)
            bubbleY = clampBubbleY(bubbleY)
        }
        val view = buildBubble(palette)
        val params = WindowManager.LayoutParams(
            dp(48), dp(48),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            x = bubbleX
            y = bubbleY
        }
        if (runCatching { windows.addView(view, params) }.isFailure) return null
        bubble = view
        bubbleParams = params
        appliedDark = palette.dark
        lastDotColor = null
        registerConfigCallbacks()
        return view
    }

    private fun buildBubble(palette: Palette): FrameLayout {
        val icon = ImageView(context).apply {
            setImageDrawable(context.applicationInfo.loadIcon(context.packageManager))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: View, outline: Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
            clipToOutline = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        val progress = ProgressBar(context, null, android.R.attr.progressBarStyleSmall).apply {
            isIndeterminate = true
            indeterminateTintList = ColorStateList.valueOf(palette.accent)
            visibility = View.GONE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        val dot = View(context).apply {
            visibility = View.GONE
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        bubbleProgress = progress
        bubbleStateDot = dot
        return FrameLayout(context).apply {
            background = bubbleBackground(palette)
            isClickable = true
            isFocusable = true
            contentDescription = bubbleDescription()
            setOnClickListener { togglePanel() }
            setOnTouchListener { view, event -> onBubbleTouch(view, event) }
            addView(icon, FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER))
            addView(progress, FrameLayout.LayoutParams(dp(18), dp(18),
                Gravity.BOTTOM or Gravity.END).apply {
                marginEnd = dp(1)
                bottomMargin = dp(1)
            })
            addView(dot, FrameLayout.LayoutParams(dp(10), dp(10),
                Gravity.BOTTOM or Gravity.END).apply {
                marginEnd = dp(3)
                bottomMargin = dp(3)
            })
        }
    }

    private fun applyBubbleAppearance(view: FrameLayout, palette: Palette) {
        view.background = bubbleBackground(palette)
        bubbleProgress?.indeterminateTintList = ColorStateList.valueOf(palette.accent)
        lastDotColor = null
    }

    private fun updateBubbleState(palette: Palette) {
        val view = bubble ?: return
        val running = !paused && !waitingForUser && operation?.state == PhoneAutomationOperationState.RUNNING
        bubbleProgress?.visibility = if (running) View.VISIBLE else View.GONE
        val dotColor = if (running) null else stateDotColor(palette)
        val dot = bubbleStateDot
        if (dotColor == null) {
            dot?.visibility = View.GONE
            lastDotColor = null
        } else if (dot != null) {
            if (lastDotColor != dotColor) {
                dot.background = oval(dotColor, palette.surface, dp(1))
                lastDotColor = dotColor
            }
            dot.visibility = View.VISIBLE
        }
        view.contentDescription = bubbleDescription()
    }

    private fun stateDotColor(palette: Palette): Int? {
        if (paused || waitingForUser) return palette.pending
        return when (operation?.state) {
            null, PhoneAutomationOperationState.RUNNING -> null
            PhoneAutomationOperationState.WAITING -> palette.pending
            PhoneAutomationOperationState.DONE -> palette.success
            PhoneAutomationOperationState.FAILED -> palette.destructive
            PhoneAutomationOperationState.UNKNOWN,
            PhoneAutomationOperationState.CANCELLED -> palette.tertiary
        }
    }

    private fun bubbleDescription(): String {
        val task = title.ifBlank { context.getString(R.string.phone_automation_title) }
        return context.getString(
            if (expanded) R.string.phone_automation_bubble_hide
            else R.string.phone_automation_bubble_show,
            task,
            statusLine(),
        )
    }

    private fun onBubbleTouch(view: View, event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.BUBBLE_DOWN,
                    event.eventTime, event.downTime, event.pointerCount)
                view.isPressed = true
                if (expanded) noteUserInteraction()
                dragDownRawX = event.rawX
                dragDownRawY = event.rawY
                val params = bubbleParams ?: return false
                dragStartX = params.x
                dragStartY = params.y
                dragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragging &&
                    (abs(event.rawX - dragDownRawX) > touchSlop ||
                        abs(event.rawY - dragDownRawY) > touchSlop)
                ) {
                    dragging = true
                }
                if (dragging) {
                    val params = bubbleParams ?: return true
                    params.x = clampBubbleX(dragStartX + (event.rawX - dragDownRawX).toInt())
                    params.y = clampBubbleY(dragStartY + (event.rawY - dragDownRawY).toInt())
                    bubbleX = params.x
                    bubbleY = params.y
                    runCatching { windows.updateViewLayout(view, params) }
                    if (expanded) positionPanel()
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.BUBBLE_UP,
                    event.eventTime, event.downTime, event.pointerCount)
                view.isPressed = false
                if (!dragging) view.performClick()
                dragging = false
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.BUBBLE_CANCEL,
                    event.eventTime, event.downTime, event.pointerCount)
                view.isPressed = false
                dragging = false
                return true
            }
        }
        return false
    }

    // -------------------------------------------------------------- panel

    private fun togglePanel() {
        if (owner == null) return
        if (expanded) {
            collapsePanel()
        } else {
            expandPanel()
        }
    }

    private fun expandPanel() {
        PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.EXPAND_REQUEST)
        if (owner == null) return
        expanded = true
        runCatching { renderOverlay() }
        if (panel == null) {
            PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.EXPAND_UNAVAILABLE)
            expanded = false
        } else {
            PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.EXPAND_OPEN)
            scheduleCollapse()
        }
        bubble?.contentDescription = bubbleDescription()
    }

    private fun collapsePanel() {
        if (approvalVisible) {
            val presentationId = approvalPresentationId
            approvalVisible = false
            approvalPresentationId = null
            approvalEnabled = false
            approvalAction = null
            approvalTarget = null
            approvalFailed = false
            val identity = approvalIdentity
            if (identity != null && presentationId != null) approvalCallbacks?.onVisibilityChanged(identity, presentationId, false)
        }
        expanded = false
        cancelCollapse()
        removePanel()
        bubble?.contentDescription = bubbleDescription()
    }

    private fun scheduleCollapse() {
        cancelCollapse()
        // An explicit approval needs enough time to read the complete target.
        // It is still retired by collapse, owner loss, Stop and lease changes.
        if (approvalVisible) return
        val expectedOwner = owner ?: return
        val expectedToken = token
        val runnable = Runnable {
            if (expanded && owner == expectedOwner && token == expectedToken) {
                collapsePanel()
            }
        }
        collapseRunnable = runnable
        main.postDelayed(runnable, COLLAPSE_DELAY_MS)
    }

    private fun cancelCollapse() {
        collapseRunnable?.let { main.removeCallbacks(it) }
        collapseRunnable = null
    }

    private fun noteUserInteraction() {
        if (!expanded || owner == null) return
        scheduleCollapse()
    }

    private fun ensurePanel(palette: Palette): LinearLayout? {
        panel?.let { return it }
        val width = panelWidthPx()
        val view = buildPanel()
        panelWidth = width
        applyPanelAppearance(view, palette)
        updatePanelContent()
        panelHeight = measurePanel(view, width)
        val params = WindowManager.LayoutParams(
            width,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.LEFT }
        val (x, y) = panelPosition(width, panelHeight)
        params.x = x
        params.y = y
        if (runCatching { windows.addView(view, params) }.isFailure) return null
        panel = view
        panelParams = params
        approvalIdentity?.let { identity ->
            val presentationId = UUID.randomUUID().toString()
            approvalPresentationId = presentationId
            approvalVisible = true
            main.post { if (isApprovalVisible(identity, presentationId)) approvalCallbacks?.onVisibilityChanged(identity, presentationId, true) }
        }
        return view
    }

    private fun buildPanel(): LinearLayout {
        // A previous add attempt may have failed after building the views;
        // force the new views to receive their content.
        lastPanelTitle = null
        lastPanelStatus = null
        lastPanelPaused = null
        // Like the notification actions, every panel action carries the
        // token that was current when this panel was built. A panel from a
        // previous owner/pause generation cannot act under a new token.
        val controlsToken = token
        val title = TextView(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            includeFontPadding = false
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val status = TextView(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            includeFontPadding = false
            maxLines = 3
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val pause = actionButton {
            noteUserInteraction()
            receive(controlsToken, if (paused) "resume" else "pause")
        }
        val takeOver = actionButton {
            noteUserInteraction()
            receive(controlsToken, "stop")
        }
        // Handle the confirmed control on touch-down, before the same touch
        // can tear down its Accessibility owner and remove this window.
        takeOver.setOnTouchListener { _, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                noteUserInteraction()
                receive(controlsToken, "stop")
            }
            true
        }
        panelTitle = title
        panelStatus = status
        panelPause = pause
        panelTakeOver = takeOver
        val actions = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        actions.addView(pause, LinearLayout.LayoutParams(0, dp(48), 1f))
        actions.addView(takeOver, LinearLayout.LayoutParams(0, dp(48), 1f).apply {
            marginStart = dp(8)
        })
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
        }
        root.addView(title, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(status, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(2)
        })
        root.addView(actions, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            topMargin = dp(10)
        })
        val identity = approvalIdentity
        if (identity != null) {
            val text = TextView(context).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setTextIsSelectable(false)
            }
            val scroller = ScrollView(context).apply { addView(text) }
            root.addView(scroller, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(120)))
            val allow = actionButton {
                val presentationId = approvalPresentationId
                if (presentationId != null && isApprovalVisible(identity, presentationId) && approvalEnabled && approvalTarget != null) {
                    approvalEnabled = false
                    updateApprovalContent()
                    approvalCallbacks?.onDecision(identity, presentationId, true)
                }
            }
            val deny = actionButton {
                val presentationId = approvalPresentationId
                if (presentationId != null && isApprovalVisible(identity, presentationId)) approvalCallbacks?.onDecision(identity, presentationId, false)
            }
            allow.text = context.getString(R.string.device_approval_allow)
            deny.text = context.getString(R.string.device_approval_deny)
            val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
            row.addView(allow, LinearLayout.LayoutParams(0, dp(48), 1f))
            row.addView(deny, LinearLayout.LayoutParams(0, dp(48), 1f))
            root.addView(row)
            approvalText = text
            approvalAllow = allow
            approvalDeny = deny
            updateApprovalContent()
        }
        root.setOnTouchListener { _, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) noteUserInteraction()
            false
        }
        return root
    }

    private fun actionButton(onClick: () -> Unit): Button = Button(context).apply {
        isAllCaps = false
        includeFontPadding = false
        gravity = Gravity.CENTER
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        maxLines = 1
        ellipsize = android.text.TextUtils.TruncateAt.END
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = 0
        setPadding(0, 0, 0, 0)
        elevation = 0f
        translationZ = 0f
        stateListAnimator = null
        backgroundTintList = null
        setOnClickListener { onClick() }
    }

    private fun applyPanelAppearance(view: LinearLayout, palette: Palette) {
        view.background = rounded(
            palette.surface, palette.separator, dp(14), 1)
        panelTitle?.setTextColor(palette.label)
        panelStatus?.setTextColor(palette.secondaryLabel)
        approvalText?.setTextColor(palette.label)
        panelPause?.apply {
            setTextColor(palette.accent)
            background = actionBackground(palette.accentFill, palette.accentFillPressed)
        }
        panelTakeOver?.apply {
            setTextColor(palette.destructive)
            background = actionBackground(palette.destructiveFill, palette.destructiveFillPressed)
        }
    }

    private fun updateApprovalContent() {
        val target = approvalTarget
        approvalText?.text = if (target == null && approvalFailed) context.getString(R.string.device_approval_unavailable)
            else if (target == null) context.getString(R.string.device_approval_checking)
            else context.getString(R.string.device_approval_click_target, target.packageName, target.label)
        approvalAllow?.isEnabled = approvalEnabled && target != null
        approvalDeny?.isEnabled = true
    }

    /** Returns true when the rendered height may have changed. */
    private fun updatePanelContent(): Boolean {
        var changed = false
        val titleText = title.ifBlank { context.getString(R.string.phone_automation_title) }
        if (lastPanelTitle != titleText) {
            panelTitle?.text = titleText
            lastPanelTitle = titleText
            changed = true
        }
        val statusText = statusLine()
        if (lastPanelStatus != statusText) {
            panelStatus?.text = statusText
            lastPanelStatus = statusText
            changed = true
        }
        if (lastPanelPaused != paused) {
            panelPause?.apply {
                text = context.getString(
                    if (paused) R.string.phone_automation_resume else R.string.phone_automation_pause)
                contentDescription = text
            }
            panelTakeOver?.apply {
                text = context.getString(R.string.phone_automation_stop)
                contentDescription = text
            }
            lastPanelPaused = paused
        }
        return changed
    }

    private fun positionPanel() {
        val view = panel ?: return
        val params = panelParams ?: return
        val height = panelHeight.takeIf { it > 0 } ?: measurePanel(view, panelWidth)
        val (x, y) = panelPosition(panelWidth, height)
        params.x = x
        params.y = y
        runCatching { windows.updateViewLayout(view, params) }
    }

    private fun panelPosition(width: Int, height: Int): Pair<Int, Int> {
        val (screenWidth, screenHeight) = screenBounds()
        val margin = dp(8)
        val gap = dp(8)
        val maxX = max(margin, screenWidth - width - margin)
        val x = (bubbleX + dp(48) - width).coerceIn(margin, maxX)
        val below = bubbleY + dp(48) + gap
        val above = bubbleY - height - gap
        val y = when {
            below + height <= screenHeight - margin -> below
            above >= margin -> above
            else -> (screenHeight - height - margin).coerceAtLeast(margin)
        }
        return x to y
    }

    private fun measurePanel(view: View, width: Int): Int {
        if (width <= 0) return 0
        val (_, screenHeight) = screenBounds()
        view.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(screenHeight, View.MeasureSpec.AT_MOST),
        )
        return view.measuredHeight
    }

    private fun panelWidthPx(): Int {
        val (screenWidth, _) = screenBounds()
        return max(dp(180), min(dp(280), screenWidth - dp(16)))
    }

    private fun removePanel() {
        panel?.let { runCatching { windows.removeViewImmediate(it) } }
        panel = null
        panelTitle = null
        panelStatus = null
        panelPause = null
        panelTakeOver = null
        approvalText = null
        approvalAllow = null
        approvalDeny = null
        panelParams = null
        panelWidth = 0
        panelHeight = 0
        lastPanelTitle = null
        lastPanelStatus = null
        lastPanelPaused = null
    }

    // ---------------------------------------------------------- lifecycle

    private fun removeOverlay() {
        PhoneControlTouchDiagnostic.record(PhoneControlTouchDiagnostic.Event.OVERLAY_REMOVE)
        retireApproval()
        cancelCollapse()
        expanded = false
        removePanel()
        bubble?.let { runCatching { windows.removeViewImmediate(it) } }
        bubble = null
        bubbleProgress = null
        bubbleStateDot = null
        bubbleParams = null
        appliedDark = null
        lastDotColor = null
        unregisterConfigCallbacks()
    }

    fun clear(expectedOwner: PhoneControlOwner? = null, retainApprovalRegistration: Boolean = false,
              deferAllowed: Boolean = true) {
        if (!retainApprovalRegistration) {
            if (expectedOwner == null) approvalRegistration.clear() else approvalRegistration.cancelOwner(expectedOwner)
        }
        val clear = clear@{
            val presentationOwner = owner ?: pendingOperation?.owner ?: operationOwner
            if (expectedOwner != null && presentationOwner != expectedOwner) return@clear
            // Keep only the already-visible panel briefly while a raw touch
            // is delivered. It grants neither control nor approval.
            if (deferAllowed && retainApprovalRegistration && expanded && expectedOwner == owner) {
                if (deferredClear == null) {
                    val oldToken = token
                    val task = Runnable {
                        deferredClear = null
                        if (token == oldToken) clear(expectedOwner, retainApprovalRegistration, false)
                    }
                    deferredClear = task
                    main.postDelayed(task, 350L)
                }
                return@clear
            }
            deferredClear?.let(main::removeCallbacks)
            deferredClear = null
            // Clearing the floating presentation must also retire the exact
            // approval lease and notify the chat card. Otherwise a takeover
            // hides the bubble/panel while the private approval stays usable.
            retireApproval()
            owner = null
            token = UUID.randomUUID().toString()
            takeoverBinding = null
            paused = false
            waitingForUser = false
            title = ""
            showOverlay = false
            operation = null
            operationOwner = null
            pendingOperation = null
            activeOperationID = null
            clearAfterOperation = false
            cancelRetireFinished()
            removeOverlay()
            notifications.cancel(NOTIFICATION)
            if (PhoneAutomationRelay.controls === this) PhoneAutomationRelay.controls = null
        }
        if (Looper.myLooper() == main.looper) clear() else main.post { clear() }
    }

    // ------------------------------------------------------ screen bounds

    private fun screenBounds(): Pair<Int, Int> {
        // Application resources track display rotation/current display size
        // for an overlay window; use them instead of an Activity token.
        val metrics = context.resources.displayMetrics
        return metrics.widthPixels to metrics.heightPixels
    }

    private fun clampBubbleX(value: Int): Int {
        val (screenWidth, _) = screenBounds()
        val margin = dp(8)
        val maxX = max(margin, screenWidth - dp(48) - margin)
        return value.coerceIn(margin, maxX)
    }

    private fun clampBubbleY(value: Int): Int {
        val (_, screenHeight) = screenBounds()
        val margin = dp(8)
        val maxY = max(margin, screenHeight - dp(48) - margin)
        return value.coerceIn(margin, maxY)
    }

    private fun clampAfterConfigurationChange() {
        if (bubble == null) return
        bubbleX = clampBubbleX(bubbleX)
        bubbleY = clampBubbleY(bubbleY)
        bubbleParams?.let { params ->
            params.x = bubbleX
            params.y = bubbleY
            bubble?.let { runCatching { windows.updateViewLayout(it, params) } }
        }
        val p = palette()
        bubble?.let {
            applyBubbleAppearance(it, p)
            updateBubbleState(p)
        }
        if (expanded && panel != null) {
            panel?.let { applyPanelAppearance(it, p) }
            // Refresh localized labels and the measured height after a
            // rotation/locale/theme configuration change.
            lastPanelTitle = null
            lastPanelStatus = null
            lastPanelPaused = null
            updatePanelContent()
            panel?.let { panelHeight = measurePanel(it, panelWidth) }
            positionPanel()
        }
        appliedDark = p.dark
    }

    private fun registerConfigCallbacks() {
        if (configCallbacksRegistered) return
        if (runCatching { context.registerComponentCallbacks(configCallbacks) }.isSuccess) {
            configCallbacksRegistered = true
        }
    }

    private fun unregisterConfigCallbacks() {
        if (!configCallbacksRegistered) return
        runCatching { context.unregisterComponentCallbacks(configCallbacks) }
        configCallbacksRegistered = false
    }

    // --------------------------------------------------------- appearance

    /**
     * Values mirror the semantic tokens in
     * `core/designsystem/.../FloeColors.kt` (light/dark). The overlay is a
     * plain View window, so it cannot read the Compose composition local;
     * keep these roles in sync with the shared theme instead of inventing a
     * separate palette.
     */
    private data class Palette(
        val dark: Boolean,
        val surface: Int,
        val label: Int,
        val secondaryLabel: Int,
        val separator: Int,
        val accent: Int,
        val accentFill: Int,
        val accentFillPressed: Int,
        val destructive: Int,
        val destructiveFill: Int,
        val destructiveFillPressed: Int,
        val pending: Int,
        val success: Int,
        val tertiary: Int,
        val bubblePressed: Int,
    )

    private fun palette(): Palette {
        val dark = when (themeStore.mode) {
            FloeThemeMode.DARK -> true
            FloeThemeMode.LIGHT -> false
            FloeThemeMode.AUTO ->
                (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
                    Configuration.UI_MODE_NIGHT_YES
        }
        return if (dark) Palette(
            dark = true,
            surface = 0xFF2C2C2E.toInt(),
            label = 0xFFFFFFFF.toInt(),
            secondaryLabel = 0xB3EBEBF5.toInt(),
            separator = 0x66545458,
            accent = 0xFF0A84FF.toInt(),
            accentFill = 0x170A84FF,
            accentFillPressed = 0x330A84FF,
            destructive = 0xFFFF453A.toInt(),
            destructiveFill = 0x17FF453A,
            destructiveFillPressed = 0x33FF453A,
            pending = 0xFFFF9F0A.toInt(),
            success = 0xFF30D158.toInt(),
            tertiary = 0x59EBEBF5,
            bubblePressed = 0xFF3A3A3C.toInt(),
        ) else Palette(
            dark = false,
            surface = 0xFFFFFFFF.toInt(),
            label = 0xFF000000.toInt(),
            secondaryLabel = 0x993C3C43.toInt(),
            separator = 0xCCC6C6C8.toInt(),
            accent = 0xFF0081F6.toInt(),
            accentFill = 0x170081F6,
            accentFillPressed = 0x330081F6,
            destructive = 0xFFFF3B30.toInt(),
            destructiveFill = 0x17FF3B30,
            destructiveFillPressed = 0x33FF3B30,
            pending = 0xFFFF9500.toInt(),
            success = 0xFF34C759.toInt(),
            tertiary = 0x4C3C3C43,
            bubblePressed = 0xFFEDF3FB.toInt(),
        )
    }

    private fun bubbleBackground(palette: Palette) = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed),
            oval(palette.bubblePressed, palette.separator, 1))
        addState(StateSet.WILD_CARD, oval(palette.surface, palette.separator, 1))
    }

    private fun actionBackground(fill: Int, pressedFill: Int) = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), rounded(pressedFill, radius = dp(10)))
        addState(StateSet.WILD_CARD, rounded(fill, radius = dp(10)))
    }

    private fun rounded(
        fill: Int,
        stroke: Int? = null,
        radius: Int = dp(10),
        strokeWidth: Int = 0,
    ) = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(fill)
        cornerRadius = radius.toFloat()
        if (stroke != null && strokeWidth > 0) setStroke(strokeWidth, stroke)
    }

    private fun oval(fill: Int, stroke: Int? = null, strokeWidth: Int = 0) =
        GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(fill)
            if (stroke != null && strokeWidth > 0) setStroke(strokeWidth, stroke)
        }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(),
            context.resources.displayMetrics).toInt()

    companion object {
        private const val CHANNEL = "phone_automation"
        private const val NOTIFICATION = 9480
        // Leave enough time to read and choose Pause or Take over on a phone.
        private const val COLLAPSE_DELAY_MS = 8_000L
        private const val FINISHED_BUBBLE_DELAY_MS = 2_000L
    }
}

internal object PhoneAutomationRelay {
    @Volatile var controls: PhoneAutomationControls? = null
}

class PhoneAutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PhoneAutomationRelay.controls?.receive(intent.getStringExtra("token"), intent.getStringExtra("action"))
    }
}
