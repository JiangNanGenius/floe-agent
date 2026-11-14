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
import android.widget.TextView
import androidx.core.app.NotificationCompat
import com.floe.android.FloeThemeStore
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.design.FloeThemeMode
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Process-local, revocable controls plus a compact, truthful floating status.
 *
 * Presentation is a 48dp draggable bubble. Tapping it opens a narrow panel
 * with the real task/action/result and the existing pause/resume and takeover
 * actions; four seconds without a user touch collapses it again. Collapsing
 * is presentation only: it never pauses, resumes, takes over, executes or
 * changes permissions. Only a real RUNNING operation animates; waiting,
 * paused, done, failed, stopped and unknown states stay static and are named
 * truthfully for accessibility.
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
internal class PhoneAutomationControls(
    private val context: Context,
    private val act: (PhoneControlOwner, Action) -> Unit,
    private val canPresent: (PhoneControlOwner) -> Boolean,
    private val ownerStillLive: (PhoneControlOwner) -> Boolean,
) {
    private val main = Handler(Looper.getMainLooper())
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val windows = context.getSystemService(WindowManager::class.java)
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val themeStore by lazy { FloeThemeStore(context) }
    private var owner: PhoneControlOwner? = null
    private var token = UUID.randomUUID().toString()
    enum class Action { PAUSE, RESUME, TAKE_OVER }

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
    private var pendingOperation: Pair<PhoneControlOwner, String>? = null

    fun show(owner: PhoneControlOwner, title: String, overlay: Boolean, paused: Boolean = false,
             waitingForUser: Boolean = false) {
        main.post {
            if (!canPresent(owner)) return@post
            if (this.owner != owner && operationOwner != owner) {
                this.operation = null
                this.operationOwner = null
            }
            if (this.paused != paused) {
                this.operation = null
                this.operationOwner = null
            }
            if (this.owner != owner || this.paused != paused) {
                removeOverlay()
                token = UUID.randomUUID().toString()
            }
            this.owner = owner
            this.paused = paused
            this.waitingForUser = waitingForUser
            this.title = PhoneAutomationStatusText.bounded(title, 48)
            showOverlay = overlay
            // The trusted pump calls start immediately before the first
            // device call, while the owner may not have been rendered yet.
            // Adopt that bounded start once it belongs to this exact owner.
            if (!paused) {
                pendingOperation?.takeIf { it.first == owner }?.let { (_, label) ->
                    operation = PhoneAutomationStatusText.operation(
                        label, PhoneAutomationOperationState.RUNNING)
                    operationOwner = owner
                    pendingOperation = null
                }
            } else {
                pendingOperation = null
            }
            PhoneAutomationRelay.controls = this
            render()
        }
    }

    /** A real claimed device operation started. UI-only; no authority. */
    fun operationStarted(owner: PhoneControlOwner, label: String) {
        main.post {
            if (!ownerStillLive(owner)) return@post
            if (paused) return@post
            if (this.owner == null) {
                pendingOperation = owner to PhoneAutomationStatusText.bounded(label, 32)
                return@post
            }
            if (this.owner != owner) return@post
            operation = PhoneAutomationStatusText.operation(
                label, PhoneAutomationOperationState.RUNNING)
            operationOwner = owner
            render()
        }
    }

    /** The actual settled outcome (or an honest unknown/cancel). */
    fun operationFinished(
        owner: PhoneControlOwner,
        label: String,
        state: PhoneAutomationOperationState,
        note: String? = null,
    ) {
        main.post {
            if (!ownerStillLive(owner)) return@post
            if (this.owner == null) {
                if (pendingOperation?.first == owner) pendingOperation = null
                operation = PhoneAutomationStatusText.operation(
                    label,
                    if (paused) PhoneAutomationOperationState.CANCELLED else state,
                    note,
                )
                operationOwner = owner
                return@post
            }
            if (this.owner != owner) return@post
            operation = PhoneAutomationStatusText.operation(
                label,
                if (paused) PhoneAutomationOperationState.CANCELLED else state,
                note,
            )
            operationOwner = owner
            render()
        }
    }

    internal fun receive(receivedToken: String?, action: String?) {
        main.post {
            if (owner == null || token != receivedToken) return@post
            val current = owner ?: return@post
            val accepted = when (action) {
                "pause" -> if (!paused) Action.PAUSE else return@post
                "resume" -> if (paused) Action.RESUME else return@post
                "stop" -> Action.TAKE_OVER
                else -> return@post
            }
            act(current, accepted)
        }
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
        if (owner == null) return
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
        if (owner == null) {
            removeOverlay()
            return
        }
        if (!showOverlay || !Settings.canDrawOverlays(context)) {
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
                view.isPressed = false
                if (!dragging) view.performClick()
                dragging = false
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
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
        if (owner == null) return
        expanded = true
        runCatching { renderOverlay() }
        if (panel == null) {
            expanded = false
        } else {
            scheduleCollapse()
        }
        bubble?.contentDescription = bubbleDescription()
    }

    private fun collapsePanel() {
        expanded = false
        cancelCollapse()
        removePanel()
        bubble?.contentDescription = bubbleDescription()
    }

    private fun scheduleCollapse() {
        cancelCollapse()
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
        panelPause?.apply {
            setTextColor(palette.accent)
            background = actionBackground(palette.accentFill, palette.accentFillPressed)
        }
        panelTakeOver?.apply {
            setTextColor(palette.destructive)
            background = actionBackground(palette.destructiveFill, palette.destructiveFillPressed)
        }
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
        panelParams = null
        panelWidth = 0
        panelHeight = 0
        lastPanelTitle = null
        lastPanelStatus = null
        lastPanelPaused = null
    }

    // ---------------------------------------------------------- lifecycle

    private fun removeOverlay() {
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

    fun clear(expectedOwner: PhoneControlOwner? = null) {
        val clear = clear@{
            val presentationOwner = owner ?: pendingOperation?.first ?: operationOwner
            if (expectedOwner != null && presentationOwner != expectedOwner) return@clear
            owner = null
            token = UUID.randomUUID().toString()
            waitingForUser = false
            operation = null
            operationOwner = null
            pendingOperation = null
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
        private const val COLLAPSE_DELAY_MS = 4_000L
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
