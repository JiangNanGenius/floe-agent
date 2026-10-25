// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.ui

import android.os.SystemClock
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloePageSheet
import com.floe.android.design.FloeSheetPlacement
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.design.IconGlyph
import com.floe.android.feature.browser.R
import com.floe.android.feature.browser.api.BrowserPanelOperation
import com.floe.android.feature.browser.api.BrowserProjectionSnapshot
import com.floe.android.feature.browser.api.BrowserServicePort
import com.floe.android.feature.browser.internal.BrowserProjectionPresenter
import com.floe.android.feature.browser.render.BrowserWebViewRenderer

/**
 * Task-first browser panel (D7): this is the EXACT owning task's browser,
 * mounted in the task inspector surface (Main routes panel-open requests to
 * it; there is no global browser tab). Every rendered fact comes from the
 * Swift projection through the presenter — the UI keeps no parallel control
 * state, and loading/failed/unavailable copy is real state, never a sample
 * page presented as product.
 */

@Composable
public fun FloeBrowserTaskSheet(
    visible: Boolean,
    onDismissRequest: () -> Unit,
    presenter: BrowserProjectionPresenter,
    service: BrowserServicePort,
    renderer: BrowserWebViewRenderer,
) {
    // Dismissing the projection never stops execution: closing the panel
    // only asks Swift to hide THIS task's panel (Swift refuses while the
    // user controls the browser; we render whatever projection comes back).
    FloePageSheet(
        visible = visible,
        onDismiss = onDismissRequest,
        widthFraction = 0.82f,
        heightFraction = 0.86f,
        placement = FloeSheetPlacement.CENTER,
    ) {
        FloeBrowserPanelContent(
            presenter = presenter,
            service = service,
            renderer = renderer,
            onCloseRequested = onDismissRequest,
        )
    }
}

@Composable
public fun FloeBrowserPanelContent(
    presenter: BrowserProjectionPresenter,
    service: BrowserServicePort,
    renderer: BrowserWebViewRenderer,
    onCloseRequested: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var state by remember(presenter) { mutableStateOf(presenter.currentState()) }
    DisposableEffect(presenter) {
        val listener: (BrowserProjectionPresenter.PanelState) -> Unit = { state = it }
        presenter.addListener(listener)
        onDispose { presenter.removeListener(listener) }
    }
    DisposableEffect(service) {
        // Bind the visible projection to THIS exact task while mounted.
        // Rebinding is presentation only; it never creates authority.
        service.bindVisible()
        onDispose { service.unbindVisible() }
    }

    val projection = state.projection
    Column(modifier = modifier.fillMaxSize()) {
        BrowserToolbarRow(
            service = service,
            onCloseRequested = onCloseRequested,
            userControls = projection?.isUserControlling == true,
        )
        FloeDivider()
        if (!state.bound || projection == null) {
            // Honest empty/unbound surface — never a sample page.
            FloeUnavailableView(
                icon = FloeBrowserIcons.Globe,
                title = stringResource(R.string.browser_unbound_title),
                description = state.unboundReason ?: stringResource(R.string.browser_unbound_hint),
            )
            return@Column
        }
        BrowserControlBanner(service = service, projection = projection)
        BrowserTabStrip(projection = projection, service = service)
        FloeDivider()
        BrowserAddressRow(service = service, projection = projection)
        FloeDivider()
        BrowserSurfaceArea(
            projection = projection,
            renderer = renderer,
            service = service,
            modifier = Modifier.weight(1f).fillMaxWidth(),
        )
    }
}

@Composable
private fun BrowserToolbarRow(
    service: BrowserServicePort,
    onCloseRequested: () -> Unit,
    userControls: Boolean,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconGlyph(FloeBrowserIcons.Globe, tint = Floe.colors.accent)
        Spacer(Modifier.width(8.dp))
        FloeText(
            text = stringResource(R.string.browser_panel_title),
            style = Floe.typography.toolbarTitle,
            color = Floe.colors.label,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        FloeCircleButton(
            icon = FloeBrowserIcons.HandTap,
            contentDescription = stringResource(R.string.browser_take_control_cd),
            onClick = { service.takeControl() },
            enabled = !userControls,
        )
        Spacer(Modifier.width(8.dp))
        FloeCircleButton(
            icon = FloeIcons.Xmark,
            contentDescription = stringResource(R.string.browser_close_panel_cd),
            onClick = onCloseRequested,
        )
    }
}

/**
 * Control banner: every value below is a projection fact. The return/continue
 * button sends the NATIVE receipt id; there is no local permission store, so
 * tab loads, timers, resume/background or view recreation can never "return
 * control" — only the receipt-bearing native path can.
 */
@Composable
private fun BrowserControlBanner(
    service: BrowserServicePort,
    projection: BrowserProjectionSnapshot,
) {
    val userControls = projection.isUserControlling
    val receiptId = projection.handoffReceiptId
    val errorMessage = projection.handoffError
    if (!userControls && receiptId == null && errorMessage == null && !projection.returningControl) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        errorMessage?.let { message ->
            FloeText(
                text = message,
                style = Floe.typography.metadata,
                color = Floe.colors.destructive,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(4.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            FloeText(
                text = stringResource(
                    if (userControls) R.string.browser_user_in_control
                    else if (projection.handoffReturning && !projection.returningControl) R.string.browser_handoff_returned
                    else R.string.browser_returning_control
                ),
                style = Floe.typography.bodyEmphasized,
                color = Floe.colors.label,
                modifier = Modifier.weight(1f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (projection.returningControl) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = Floe.colors.accent)
            } else {
                receiptId?.let { receipt ->
                    FloeCircleButton(
                        icon = FloeIcons.Checkmark,
                        contentDescription = stringResource(
                            if (projection.handoffNeedsContinue) R.string.browser_continue_task
                            else R.string.browser_return_control_cd
                        ),
                        onClick = { service.returnToAgent(receiptId = receipt, continueTask = projection.handoffNeedsContinue) },
                    )
                }
            }
        }
    }
}

@Composable
private fun BrowserTabStrip(
    projection: BrowserProjectionSnapshot,
    service: BrowserServicePort,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        projection.tabs.forEach { tab ->
            val selected = tab.id == projection.activeTabId
            Row(
                modifier = Modifier
                    .heightIn(min = 36.dp)
                    .clickable(enabled = !selected) {
                        service.performPanelOperation(BrowserPanelOperation.Activate(tab.id))
                    }
                    .padding(horizontal = 10.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeText(
                    text = tab.title.ifBlank {
                        tab.url.ifBlank { stringResource(R.string.browser_new_tab) }
                    },
                    style = if (selected) Floe.typography.bodyEmphasized else Floe.typography.body,
                    color = if (selected) Floe.colors.accent else Floe.colors.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 180.dp),
                )
                if (!selected && projection.tabs.size > 1) {
                    Spacer(Modifier.width(4.dp))
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clickable { service.performPanelOperation(BrowserPanelOperation.Close(tab.id)) },
                        contentAlignment = Alignment.Center,
                    ) {
                        IconGlyph(FloeIcons.Xmark, tint = Floe.colors.tertiaryLabel, size = 14.dp)
                    }
                }
            }
        }
        FloeCircleButton(
            icon = FloeIcons.Plus,
            contentDescription = stringResource(R.string.browser_new_tab_cd),
            onClick = { service.performPanelOperation(BrowserPanelOperation.CreateTab) },
        )
    }
}

@Composable
private fun BrowserAddressRow(
    service: BrowserServicePort,
    projection: BrowserProjectionSnapshot,
) {
    var text by remember(projection.activeTabId) { mutableStateOf(projection.addressText) }
    // One physical Enter can arrive BOTH as a raw hardware key event and as
    // an IME Go action on some devices; this short window makes a single
    // Enter (or a repeated tap) commit exactly once through the owned
    // native call — it never replaces the native commit path.
    var lastCommitElapsed by remember { mutableLongStateOf(0L) }
    fun commitDraft() {
        val now = SystemClock.elapsedRealtime()
        if (text.isBlank() || now - lastCommitElapsed < 350L) return
        lastCommitElapsed = now
        service.navigateFromAddressBar(draft = text)
    }
    // Follow native truth whenever the session is not locally editing. Commit
    // sends the text to Swift, which applies URL policy + preview-reload
    // rules and answers through the projection; nothing is decided here.
    DisposableEffect(projection.addressText, projection.isEditingAddress) {
        if (!projection.isEditingAddress) text = projection.addressText
        onDispose {}
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FloeCircleButton(
            icon = FloeIcons.ChevronBack,
            contentDescription = stringResource(R.string.browser_back_cd),
            onClick = { service.goBackTab() },
        )
        Spacer(Modifier.width(6.dp))
        FloeCircleButton(
            icon = FloeIcons.ChevronForward,
            contentDescription = stringResource(R.string.browser_forward_cd),
            onClick = { service.goForwardTab() },
        )
        Spacer(Modifier.width(8.dp))
        Box(
            modifier = Modifier
                .weight(1f)
                .heightIn(min = 36.dp)
                .padding(horizontal = 10.dp, vertical = 8.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            if (text.isEmpty()) {
                FloeText(
                    stringResource(R.string.browser_address_placeholder),
                    style = Floe.typography.body,
                    color = Floe.colors.tertiaryLabel,
                    maxLines = 1,
                )
            }
            BasicTextField(
                value = text,
                onValueChange = {
                    text = it
                    service.setAddressText(it)
                },
                singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(
                    fontSize = 15.sp,
                    color = Floe.colors.label,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(
                    onGo = {
                        commitDraft()
                    },
                ),
                cursorBrush = SolidColor(Floe.colors.accent),
                modifier = Modifier.fillMaxWidth()
                    .clickable { service.setEditingAddress(true) }
                    .onPreviewKeyEvent { event ->
                        if (event.key == Key.Enter && event.type == KeyEventType.KeyUp) {
                            // Hardware keyboards deliver Enter as key events
                            // only; the soft IME action never passes through
                            // this handler, so the two paths cannot double
                            // dispatch (and commitDraft de-duplicates if a
                            // device sends both).
                            commitDraft()
                            true
                        } else {
                            false
                        }
                    },
            )
        }
        if (projection.isDisplayingLocalPreview) {
            Spacer(Modifier.width(8.dp))
            FloeText(
                text = stringResource(R.string.browser_local_preview_badge),
                style = Floe.typography.groupHeader,
                color = Floe.colors.accent,
                maxLines = 1,
            )
        }
        Spacer(Modifier.width(8.dp))
        FloeCircleButton(
            icon = FloeBrowserIcons.Go,
            contentDescription = stringResource(R.string.browser_go_cd),
            onClick = { commitDraft() },
            enabled = text.isNotBlank(),
        )
        Spacer(Modifier.width(8.dp))
        FloeCircleButton(
            icon = FloeBrowserIcons.Retry,
            contentDescription = stringResource(R.string.browser_reload_cd),
            onClick = { service.requestReload() },
        )
    }
}

/**
 * The page surface. The active tab's real WebView is re-parented in for
 * projection only; every state overlay is a native projection fact. When the
 * surface host is absent the tab still EXISTS (background execution); the
 * viewer simply shows what native surface state honestly reports — never a
 * placeholder page.
 */
@Composable
private fun BrowserSurfaceArea(
    projection: BrowserProjectionSnapshot,
    renderer: BrowserWebViewRenderer,
    service: BrowserServicePort,
    modifier: Modifier = Modifier,
) {
    val activeTab = projection.activeTabId
    Box(modifier = modifier.fillMaxSize()) {
        if (activeTab != null) {
            val host = remember(activeTab) { SurfaceHostHolder() }
            AndroidView(
                factory = { context ->
                    FrameLayout(context).also { host.container = it }
                },
                update = { container ->
                    if (host.boundTabId != activeTab) {
                        container.getChildAt(0)?.let { old ->
                            container.removeView(old)
                            host.boundTabId?.let { renderer.releaseFromProjection(it) }
                        }
                        val view = renderer.surfaceForProjection(activeTab)
                        if (view != null) {
                            (view.parent as? android.view.ViewGroup)?.removeView(view)
                            container.addView(
                                view,
                                android.view.ViewGroup.LayoutParams(
                                    android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                                    android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                                ),
                            )
                        }
                        host.boundTabId = activeTab
                    }
                },
                onRelease = { container ->
                    container.getChildAt(0)?.let { container.removeView(it) }
                    host.boundTabId?.let { renderer.releaseFromProjection(it) }
                    host.boundTabId = null
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
        when (projection.surfaceStateKind) {
            "loading" -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                if (projection.isUserControlling.not()) {
                    CircularProgressIndicator(color = Floe.colors.accent)
                }
            }
            "failed" -> Column(
                modifier = Modifier.fillMaxSize().padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                var detailsExpanded by remember(projection.surfaceStateDetail) { mutableStateOf(false) }
                val detail = projection.surfaceStateDetail
                FloeText(
                    text = if (detail == "Loopback and private-network navigation is blocked") {
                        stringResource(R.string.browser_private_navigation_blocked)
                    } else {
                        stringResource(R.string.browser_load_failed)
                    },
                    style = Floe.typography.section,
                    color = Floe.colors.label,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                if (!detail.isNullOrBlank() &&
                    detail != "The page could not be loaded." &&
                    detail != "Loopback and private-network navigation is blocked") {
                    Spacer(Modifier.height(12.dp))
                    FloeCapsuleButton(stringResource(R.string.browser_failure_details),
                        onClick = { detailsExpanded = !detailsExpanded })
                    if (detailsExpanded) {
                        FloeText(detail.take(2048), style = Floe.typography.metadata,
                            color = Floe.colors.secondaryLabel)
                    }
                }
                Spacer(Modifier.height(12.dp))
                FloeCircleButton(
                    icon = FloeBrowserIcons.Retry,
                    contentDescription = stringResource(R.string.browser_retry_cd),
                    onClick = { service.requestReload() },
                )
            }
            "needsUser" -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.BottomCenter,
            ) {
                FloeText(
                    text = projection.surfaceStateDetail
                        ?: stringResource(R.string.browser_user_in_control),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.padding(bottom = 12.dp),
                )
            }
        }
    }
}

private class SurfaceHostHolder {
    var container: FrameLayout? = null
    var boundTabId: String? = null
}
