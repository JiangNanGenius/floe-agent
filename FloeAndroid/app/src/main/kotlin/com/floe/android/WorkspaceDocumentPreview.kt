// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import androidx.compose.foundation.Image as ComposeImage
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeUnavailableView
import com.floe.android.host.Owner
import com.floe.android.host.WorkspaceDocumentPreviewController
import com.floe.android.host.WorkspaceDocumentPreviewPolicy
import com.floe.android.host.WorkspacePreviewKind
import com.floe.android.host.WorkspacePreviewState

/**
 * Full-window READ-ONLY PDF/raster preview built ONLY from the existing
 * verified components:
 *  - the verified workspace snapshot transport + isolated Office PDF
 *    renderer + RAM-only password broker live in
 *    [WorkspaceDocumentPreviewController];
 *  - this file renders the published immutable state with the existing Floe
 *    toolbar/geometry. No file path, model text or renderer identity is
 *    shown; no save/edit/import action exists here.
 *
 * Lifecycle: the controller is Application-owned. [LaunchedEffect] sends the
 * one open intent; a rotation restores the same `rememberSaveable` request
 * token and open is a no-op while that exact session is live. The dialog
 * owner closes it on real navigation (see WorkspaceDocumentDestination).
 */
@Composable
internal fun WorkspaceDocumentPreview(
    controller: WorkspaceDocumentPreviewController,
    request: WorkspaceDocumentRequest,
    kind: WorkspacePreviewKind,
    owner: Owner,
    onBackToFiles: () -> Unit,
    onCloseTask: () -> Unit,
) {
    val state by controller.state.collectAsState()
    LaunchedEffect(request.token, request.path, owner.nativeEpoch, owner.hostGeneration) {
        controller.open(owner, request.path, kind, request.token)
    }
    val current = state.takeIf { it.requestToken() == request.token }
    if (current is WorkspacePreviewState.Failed &&
        current.failure == WorkspacePreviewState.Failure.OWNER
    ) {
        // The captured owner retired (task/root/generation): no stale
        // document may stay on screen. Leave the exact file list behind.
        LaunchedEffect(current) { onBackToFiles() }
    }
    Column(Modifier.fillMaxSize().testTag("workspace.documentPreview")) {
        WorkspaceDocumentHeader(
            fileName = request.fileName,
            onBackToFiles = onBackToFiles,
            onCloseTask = onCloseTask,
        )
        com.floe.android.design.FloeDivider()
        Box(Modifier.fillMaxSize()) {
            when (val value = current) {
                null, WorkspacePreviewState.Idle,
                is WorkspacePreviewState.Opening,
                is WorkspacePreviewState.PasswordRequired,
                -> PreviewStatus(
                    isPassword = value is WorkspacePreviewState.PasswordRequired,
                )

                is WorkspacePreviewState.Pdf -> PdfPreview(
                    state = value,
                    onPrev = { controller.selectPage(value.token, value.pageIndex - 1) },
                    onNext = { controller.selectPage(value.token, value.pageIndex + 1) },
                    onZoomOut = {
                        controller.setZoom(value.token, WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.nextZoomIndex(
                                WorkspaceDocumentPreviewPolicy.zoomIndexFor(value.zoomPercent), -1)))
                    },
                    onZoomIn = {
                        controller.setZoom(value.token, WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.nextZoomIndex(
                                WorkspaceDocumentPreviewPolicy.zoomIndexFor(value.zoomPercent), 1)))
                    },
                    onZoomFit = {
                        controller.setZoom(value.token, WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.DEFAULT_ZOOM_INDEX))
                    },
                    onRetryPage = { controller.retryPage(value.token) },
                )

                is WorkspacePreviewState.Image -> ImagePreview(
                    state = value,
                    onZoomOut = {
                        controller.setZoom(value.token, WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.nextZoomIndex(
                                WorkspaceDocumentPreviewPolicy.zoomIndexFor(value.zoomPercent), -1)))
                    },
                    onZoomIn = {
                        controller.setZoom(value.token, WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.nextZoomIndex(
                                WorkspaceDocumentPreviewPolicy.zoomIndexFor(value.zoomPercent), 1)))
                    },
                    onZoomFit = {
                        controller.setZoom(value.token, WorkspaceDocumentPreviewPolicy.zoomPercent(
                            WorkspaceDocumentPreviewPolicy.DEFAULT_ZOOM_INDEX))
                    },
                )

                is WorkspacePreviewState.Failed -> PreviewFailure(
                    state = value,
                    onRetry = { controller.retry(value.token) },
                )
            }
        }
    }
    // The EXISTING owner-gated RAM-only prompt (same broker/dialog Notes
    // uses); it renders nothing unless a request is pending.
    NotesPdfPasswordDialog(controller.passwordPrompts)
}

@Composable
private fun PreviewStatus(isPassword: Boolean) {
    Column(
        modifier = Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (isPassword) {
            com.floe.android.design.IconGlyph(
                FloeIcons.ShieldCheck, Floe.colors.secondaryLabel, 32.dp)
            FloeText(
                stringResource(R.string.workspace_document_preview_password_title),
                style = Floe.typography.section,
                color = Floe.colors.label,
                modifier = Modifier.padding(top = 12.dp),
            )
            FloeText(
                stringResource(R.string.workspace_document_preview_password_needed),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 6.dp),
            )
        } else {
            FloeActivityIndicator(Modifier.size(24.dp))
            FloeText(
                stringResource(R.string.workspace_document_preview_opening),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
    }
}

@Composable
private fun PreviewFailure(state: WorkspacePreviewState.Failed, onRetry: () -> Unit) {
    FloeUnavailableView(
        icon = FloeIcons.WarningTriangle,
        title = stringResource(
            if (state.failure == WorkspacePreviewState.Failure.PASSWORD_REJECTED ||
                state.failure == WorkspacePreviewState.Failure.PASSWORD_REQUIRED ||
                state.failure == WorkspacePreviewState.Failure.PASSWORD_UNSUPPORTED
            ) {
                R.string.workspace_document_preview_password_title
            } else {
                R.string.workspace_document_preview_failed_title
            },
        ),
        description = stringResource(
            when (state.failure) {
                WorkspacePreviewState.Failure.OWNER -> R.string.workspace_document_preview_owner
                WorkspacePreviewState.Failure.SOURCE -> R.string.workspace_document_preview_source
                WorkspacePreviewState.Failure.TOO_LARGE -> R.string.workspace_document_preview_too_large
                WorkspacePreviewState.Failure.INVALID -> R.string.workspace_document_preview_invalid
                WorkspacePreviewState.Failure.UNSUPPORTED -> R.string.workspace_document_preview_unsupported
                WorkspacePreviewState.Failure.PASSWORD_REQUIRED ->
                    R.string.workspace_document_preview_password_needed
                WorkspacePreviewState.Failure.PASSWORD_REJECTED ->
                    R.string.workspace_document_preview_password_rejected
                WorkspacePreviewState.Failure.PASSWORD_UNSUPPORTED ->
                    R.string.workspace_document_preview_password_unsupported
                WorkspacePreviewState.Failure.TRANSPORT -> R.string.workspace_document_preview_transport
                WorkspacePreviewState.Failure.RENDER -> R.string.workspace_document_preview_render
            },
        ),
        modifier = Modifier.testTag("workspace.documentPreviewFailure"),
        action = if (state.retryable) {
            {
                FloeCapsuleButton(
                    stringResource(R.string.workspace_document_preview_retry),
                    onClick = onRetry,
                    modifier = Modifier.testTag("workspace.documentPreviewRetry"),
                )
            }
        } else {
            null
        },
    )
}

@Composable
private fun PdfPreview(
    state: WorkspacePreviewState.Pdf,
    onPrev: () -> Unit,
    onNext: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomIn: () -> Unit,
    onZoomFit: () -> Unit,
    onRetryPage: () -> Unit,
) {
    Column(Modifier.fillMaxSize()) {
        PdfPageViewport(
            modifier = Modifier.fillMaxWidth().weight(1f),
            page = state.pages[state.pageIndex],
            pageIndex = state.pageIndex,
            zoomPercent = state.zoomPercent,
            onRetryPage = onRetryPage,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeCircleButton(
                icon = FloeIcons.ChevronBack,
                contentDescription = stringResource(R.string.workspace_document_pdf_prev),
                onClick = onPrev,
                enabled = state.pageIndex > 0,
                visualSize = 36.dp,
                iconSize = 18.dp,
            )
            FloeText(
                text = stringResource(
                    R.string.workspace_document_pdf_page_indicator,
                    state.pageIndex + 1,
                    state.pageCount,
                ),
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                modifier = Modifier.weight(1f),
            )
            FloeCircleButton(
                icon = FloeIcons.ChevronForward,
                contentDescription = stringResource(R.string.workspace_document_pdf_next),
                onClick = onNext,
                enabled = state.pageIndex < state.pageCount - 1,
                visualSize = 36.dp,
                iconSize = 18.dp,
            )
            Spacer(Modifier.width(10.dp))
            ZoomTextChip(
                label = "\u2212",
                description = stringResource(R.string.workspace_document_zoom_out),
                onClick = onZoomOut,
            )
            ZoomTextChip(
                label = stringResource(R.string.workspace_document_zoom_fit),
                description = stringResource(R.string.workspace_document_zoom_fit),
                onClick = onZoomFit,
            )
            ZoomTextChip(
                label = "+",
                description = stringResource(R.string.workspace_document_zoom_in),
                onClick = onZoomIn,
            )
        }
    }
}

@Composable
private fun PdfPageViewport(
    modifier: Modifier,
    page: WorkspacePreviewState.Page?,
    pageIndex: Int,
    zoomPercent: Int,
    onRetryPage: () -> Unit,
) {
    val screenWidthDp = LocalConfiguration.current.screenWidthDp.toFloat()
    val displayWidth: Dp = (screenWidthDp * zoomPercent / 100f).dp
    val vertical = rememberScrollState()
    val horizontal = rememberScrollState()
    LaunchedEffect(pageIndex, zoomPercent) {
        vertical.scrollTo(0)
        horizontal.scrollTo(0)
    }
    Box(modifier.testTag("workspace.documentPdfPage"), contentAlignment = Alignment.TopStart) {
        when (page) {
            null, WorkspacePreviewState.Page.Loading -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                FloeActivityIndicator(Modifier.size(24.dp))
            }

            is WorkspacePreviewState.Page.Ready -> {
                val height = displayWidth * (page.heightPx.toFloat() / page.widthPx.toFloat())
                ComposeImage(
                    bitmap = page.bitmap.asImageBitmap(),
                    contentDescription = null,
                    modifier = Modifier
                        .verticalScroll(vertical)
                        .horizontalScroll(horizontal)
                        .width(displayWidth)
                        .height(height),
                )
            }

            is WorkspacePreviewState.Page.Failed -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.padding(24.dp),
                ) {
                    FloeText(
                        text = stringResource(R.string.workspace_document_preview_render),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                    )
                    if (page.retryable) {
                        FloeText(
                            text = stringResource(R.string.workspace_document_preview_retry),
                            style = Floe.typography.metadata,
                            color = Floe.colors.accent,
                            modifier = Modifier
                                .clickable(onClick = onRetryPage)
                                .padding(12.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ImagePreview(
    state: WorkspacePreviewState.Image,
    onZoomOut: () -> Unit,
    onZoomIn: () -> Unit,
    onZoomFit: () -> Unit,
) {
    val screenWidthDp = LocalConfiguration.current.screenWidthDp.toFloat()
    val displayWidth: Dp = (screenWidthDp * state.zoomPercent / 100f).dp
    val displayHeight = displayWidth * (state.heightPx.toFloat() / state.widthPx.toFloat())
    val vertical = rememberScrollState()
    val horizontal = rememberScrollState()
    LaunchedEffect(state.token, state.zoomPercent) {
        vertical.scrollTo(0)
        horizontal.scrollTo(0)
    }
    Column(Modifier.fillMaxSize()) {
        Box(
            Modifier.fillMaxWidth().weight(1f).testTag("workspace.documentImage"),
            contentAlignment = Alignment.TopStart,
        ) {
            ComposeImage(
                bitmap = state.bitmap.asImageBitmap(),
                contentDescription = state.fileName,
                modifier = Modifier
                    .verticalScroll(vertical)
                    .horizontalScroll(horizontal)
                    .width(displayWidth)
                    .height(displayHeight),
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            FloeText(
                text = state.fileName,
                style = Floe.typography.metadata,
                color = Floe.colors.secondaryLabel,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            ZoomTextChip(
                label = "\u2212",
                description = stringResource(R.string.workspace_document_zoom_out),
                onClick = onZoomOut,
            )
            ZoomTextChip(
                label = stringResource(R.string.workspace_document_zoom_fit),
                description = stringResource(R.string.workspace_document_zoom_fit),
                onClick = onZoomFit,
            )
            ZoomTextChip(
                label = "+",
                description = stringResource(R.string.workspace_document_zoom_in),
                onClick = onZoomIn,
            )
        }
    }
}

/** Small text chip for the bounded zoom row (same geometry as the accepted
 * Office PDF preview; no new glyph or large command surface is invented). */
@Composable
private fun ZoomTextChip(label: String, description: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .heightIn(min = 36.dp)
            .semantics {
                contentDescription = description
                role = Role.Button
            }
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(18.dp))
            .background(Floe.colors.chromeSurface, RoundedCornerShape(18.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        FloeText(text = label, style = Floe.typography.metadata, color = Floe.colors.label)
    }
}

/** The token of this state, or null for Idle: the UI must never render one
 * request's document under another request's chrome. */
internal fun WorkspacePreviewState.requestToken(): Long? = when (this) {
    WorkspacePreviewState.Idle -> null
    is WorkspacePreviewState.Opening -> token
    is WorkspacePreviewState.Pdf -> token
    is WorkspacePreviewState.Image -> token
    is WorkspacePreviewState.PasswordRequired -> token
    is WorkspacePreviewState.Failed -> token
}
