// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.browser.api.BrowserServiceCallbacks
import com.floe.android.feature.browser.internal.BrowserProjectionPresenter
import com.floe.android.feature.browser.ui.FloeBrowserPanelContent
import com.floe.android.feature.browser.ui.FloeBrowserTaskSheet
import com.floe.android.host.BrowserHostController
import com.floe.android.host.RuntimeHost

/**
 * Real task-owned browser panel (G04-R1, decision D7). This is the EXACT
 * owning ordinary task's browser: it wraps the supplied `feature/browser`
 * secondary-sheet UI and drives ONLY the native BrowserSessionCenter
 * through the RuntimeHost-owned [BrowserHostController] bindings. The pane
 * owns nothing about the session itself:
 *  * closing the panel asks Swift to hide the panel (refused while the user
 *    controls the browser); it never stops previews, cancels downloads or
 *    destroys tabs — service lifetime outlives this composition;
 *  * back/forward/address/retry/tabs/Continue/close all operate the same
 *    native center through the typed service port;
 *  * persisted cookies are REAL process-global WebView storage (the
 *    platform has no incognito isolation; feature/browser renders that as
 *    a typed limitation, never a fake private mode);
 *  * every rendered fact comes from the Swift projection through the
 *    owner-fenced presenter — a foreign or epoch-stale projection shows the
 *    honest unbound surface.
 *
 * Main mounts it inside the task inspector/secondary-sheet composition for
 * the SELECTED ordinary task and routes native panel requests to it; there
 * is no global browser tab.
 */
@Composable
internal fun WorkspaceBrowserPane(
    taskID: String,
    visible: Boolean,
    onDismissRequest: () -> Unit,
    host: RuntimeHost,
    modifier: Modifier = Modifier,
) {
    val state = rememberBrowserBinding(host, taskID)
    val binding = state.binding
    if (binding == null) {
        // Honest unbound surface while (or after) the exact-owner acquire
        // refused: never a sample page, never a local control state.
        BrowserUnavailable(state, modifier)
        return
    }
    FloeBrowserTaskSheet(
        visible = visible,
        onDismissRequest = onDismissRequest,
        presenter = binding.presenter,
        service = binding.service,
        renderer = binding.renderer,
    )
}

/** Embedded (two-column / inspector) variant for Main's layout decisions:
 * the SAME exact-owner fence, without the sheet chrome. */
@Composable
internal fun WorkspaceBrowserPanelEmbedded(
    taskID: String,
    host: RuntimeHost,
    onCloseRequested: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = rememberBrowserBinding(host, taskID)
    val binding = state.binding
    if (binding == null) {
        BrowserUnavailable(state, modifier)
        return
    }
    DisposableEffect(binding) {
        binding.service.bindVisible()
        binding.service.consumePendingPanelRequest()
        onDispose { binding.service.unbindVisible() }
    }
    val previewStatus by host.browser.previewStatus.collectAsState()
    androidx.compose.foundation.layout.Column(modifier) {
        when (previewStatus.entries.firstOrNull { it.key.equals(taskID, true) }?.value) {
            "pending" -> com.floe.android.design.FloeText(stringResource(R.string.browser_preview_starting),
                style = com.floe.android.design.Floe.typography.metadata)
            "unknown" -> com.floe.android.design.FloeText(stringResource(R.string.browser_preview_waiting),
                style = com.floe.android.design.Floe.typography.metadata)
            "failed" -> com.floe.android.design.FloeText(stringResource(R.string.browser_preview_failed),
                style = com.floe.android.design.Floe.typography.metadata)
        }
    FloeBrowserPanelContent(
        presenter = binding.presenter,
        service = binding.service,
        renderer = binding.renderer,
        onCloseRequested = onCloseRequested,
        modifier = Modifier.fillMaxSize(),
    )
    }
}

/**
 * Offscreen renderer host: Main mounts this ONCE in the Activity/Root
 * composition (clipped/hidden by Main's visual choice) sized to the real
 * 1024x768-dp viewport, so BACKGROUND tabs of every live binding can be
 * laid out, OBSERVED and MEASURED honestly (the iOS offscreen-frame parity
 * documented in feature/browser). Service lifetime never depends on this
 * composable: unmounting only detaches the layout container; tabs and
 * sessions keep running.
 */
@Composable
internal fun BrowserOffscreenHost(
    taskID: String,
    host: RuntimeHost,
    modifier: Modifier = Modifier,
) {
    AndroidView(
        modifier = modifier.fillMaxSize(),
        factory = { context ->
            object : FrameLayout(context) {
                override fun dispatchTouchEvent(event: android.view.MotionEvent?): Boolean = false
            }.apply {
                importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                isClickable = false
                isFocusable = false
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                post { host.browser.attachOffscreenHost(taskID, this) }
            }
        },
        onRelease = { container ->
            host.browser.detachOffscreenHost(taskID)
            (container.parent as? ViewGroup)?.removeView(container)
        },
    )
}

// MARK: - shared acquire state

@Composable
private fun rememberBrowserBinding(
    host: RuntimeHost,
    taskID: String,
): BrowserPaneState {
    val context = androidx.compose.ui.platform.LocalContext.current
    val state = remember(host, taskID) { BrowserPaneState() }
    val callbacks = remember {
        object : BrowserServiceCallbacks {
            override fun onCommandResult(requestId: String, resultJson: String) {}
            override fun onToolResult(
                requestId: String, toolName: String, ok: Boolean, summaryJson: String,
                requiresUserAction: Boolean, errorCode: String?,
            ) {}

            override fun onPopupDecision(requestId: String, decisionJson: String) {}
            override fun onDownloadSignal(signalJson: String) {}
            override fun onProjection(projectionJson: String) {}
        }
    }
    val epoch by host.browser.nativeEpoch.collectAsState()
    LaunchedEffect(host, taskID, epoch, state.attempt) {
        state.binding = null
        state.refusal = null
        runCatching {
            val epoch = host.nativeRootEpoch() ?: throw BrowserHostController.Failure("ownerUnavailable")
            com.floe.android.host.G04WorkspaceBridgeClient.bind(host, taskID) {
                host.nativeRootEpoch() == epoch && host.conversations.entryFor(taskID)?.isTemporary == false
            }
            host.browser.acquire(taskID)
        }
            .onSuccess { binding ->
                state.binding = binding
                state.refusal = null
                binding.service.attach(callbacks)
            }
            .onFailure { error ->
                state.binding = null
                state.refusal = browserUnboundCopy(error, context)
            }
    }
    DisposableEffect(state, host, taskID) {
        onDispose {
            // View disposal NEVER touches sessions, previews or downloads.
            // It only stops repainting THIS composition; the native visible
            // binding ends through the sheet's own (presentation-only)
            // unbindVisible path.
        }
    }
    return state
}

private class BrowserPaneState {
    var attempt by mutableStateOf(0)
    var binding: BrowserHostController.Binding? by mutableStateOf(null)
    var refusal: String? by mutableStateOf(null)
}

@Composable
private fun BrowserUnavailable(state: BrowserPaneState, modifier: Modifier) {
    androidx.compose.foundation.layout.Column(modifier.fillMaxSize()) {
        FloeUnavailableView(
            icon = com.floe.android.feature.browser.ui.FloeBrowserIcons.Globe,
            title = stringResource(com.floe.android.feature.browser.R.string.browser_unbound_title),
            description = state.refusal ?: stringResource(com.floe.android.feature.browser.R.string.browser_unbound_hint),
            modifier = Modifier.weight(1f),
        )
        if (state.refusal != null) com.floe.android.design.FloeCapsuleButton(
            stringResource(R.string.workspace_retry), onClick = { state.attempt++ },
            modifier = Modifier.padding(12.dp),
        )
    }
}

private fun browserUnboundCopy(error: Throwable, context: android.content.Context): String =
    context.getString(when ((error as? BrowserHostController.Failure)?.code ?: error.message) {
        "temporaryChat" -> com.floe.android.feature.browser.R.string.browser_temporary_unbound
        "ownerUnavailable", "pumpUnbound" -> R.string.browser_task_starting
        "workspaceUnbound" -> R.string.browser_task_workspace_missing
        "taskMissing", "invalidTask" -> R.string.browser_task_missing
        else -> R.string.browser_task_unavailable
    })
