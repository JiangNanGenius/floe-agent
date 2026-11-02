// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import android.util.TypedValue
import android.widget.TextView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCapsuleAction
import com.floe.android.design.FloeDivider
import com.floe.android.design.FloeText
import com.floe.android.feature.notes.ui.R
import com.floe.android.feature.notes.ui.presentation.NotesPdfTextNotice
import com.floe.android.feature.notes.ui.state.NotesDocumentSession
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

/**
 * Always-visible controls for the dedicated PDF text-selection mode. It is
 * rendered above the page footer so a selection target does not move the
 * actions off-screen on a phone.
 */
@Composable
internal fun NotesPdfTextBar(
    session: NotesDocumentSession,
    onOpenFullText: () -> Unit,
    onRequestOcr: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_600)
            copied = false
        }
    }
    val selection = session.pdfTextSelection
    val notice = session.pdfTextNotice
    LaunchedEffect(selection?.startChar, selection?.endChar) { copied = false }
    LaunchedEffect(session.pdfTextMode) {
        while (session.pdfTextMode) {
            delay(500)
            session.fencePdfTextIfStale()
        }
    }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 6.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Floe.colors.chromeSurface)
            .border(0.5.dp, Floe.colors.chromeHairline, RoundedCornerShape(14.dp)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
            when {
                session.pdfTextLoading -> {
                    FloeActivityIndicator()
                    FloeText(
                        stringResource(R.string.notes_pdf_text_loading),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                notice != null -> {
                    FloeText(
                        pdfTextNoticeText(notice),
                        style = Floe.typography.metadata,
                        color = if (notice == NotesPdfTextNotice.GEOMETRY_MISMATCH) {
                            Floe.colors.secondaryLabel
                        } else {
                            Floe.colors.pending
                        },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (notice == NotesPdfTextNotice.GEOMETRY_MISMATCH &&
                        session.pdfTextPage != null
                    ) {
                        FloeCapsuleAction(
                            stringResource(R.string.notes_pdf_text_full_text),
                            onClick = onOpenFullText,
                            showHairline = false,
                        )
                    }
                    if ((notice == NotesPdfTextNotice.NO_TEXT ||
                            notice == NotesPdfTextNotice.NATIVE_TEXT_UNSUPPORTED) &&
                        onRequestOcr != null
                    ) {
                        FloeCapsuleAction(
                            stringResource(R.string.notes_ocr_recognize),
                            onClick = { onRequestOcr?.invoke() },
                            showHairline = false,
                        )
                    }
                }
                selection != null -> {
                    FloeText(
                        stringResource(
                            R.string.notes_pdf_text_selection_count,
                            selection.text.codePointCount(0, selection.text.length),
                        ),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                    )
                    if (selection.truncated) {
                        FloeText(
                            stringResource(R.string.notes_pdf_text_partial),
                            style = Floe.typography.metadata,
                            color = Floe.colors.pending,
                            maxLines = 1,
                        )
                    }
                    FloeCapsuleAction(
                        stringResource(
                            if (copied) R.string.notes_pdf_text_copied else R.string.notes_pdf_text_copy,
                        ),
                        onClick = {
                            val text = session.copyablePdfText()
                            if (text != null) {
                                clipboard.setText(AnnotatedString(text))
                                copied = true
                            }
                        },
                        showHairline = false,
                    )
                    FloeCapsuleAction(
                        stringResource(R.string.notes_pdf_text_full_text),
                        onClick = onOpenFullText,
                        showHairline = false,
                    )
                }
                else -> {
                    FloeText(
                        stringResource(R.string.notes_pdf_text_mode_hint),
                        style = Floe.typography.metadata,
                        color = Floe.colors.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (session.pdfTextPage?.truncated == true) {
                        FloeText(
                            stringResource(R.string.notes_pdf_text_partial),
                            style = Floe.typography.metadata,
                            color = Floe.colors.pending,
                            maxLines = 1,
                        )
                    }
                    FloeCapsuleAction(
                        stringResource(R.string.notes_pdf_text_select_all),
                        onClick = session::selectAllPdfText,
                        showHairline = false,
                    )
                    FloeCapsuleAction(
                        stringResource(R.string.notes_pdf_text_full_text),
                        onClick = onOpenFullText,
                        showHairline = false,
                    )
                }
            }
            }
            FloeCapsuleAction(
                stringResource(R.string.notes_done),
                onClick = session::exitPdfTextMode,
                showHairline = false,
            )
        }
    }
}

/**
 * Secondary full-page text surface. A platform TextView is used deliberately:
 * it provides native character-level selection handles and the system Copy
 * action over the extracted text, while the identity line keeps the source
 * page explicit. Copying remains an explicit user action.
 */
@Composable
internal fun NotesPdfTextSheet(
    session: NotesDocumentSession,
    pdfPageNumber: Int,
    visible: Boolean,
    onDismiss: () -> Unit,
) {
    if (!visible) return
    val clipboard = LocalClipboardManager.current
    val density = LocalDensity.current.density
    val textColor = Floe.colors.label.toArgb()
    val pageText = session.pdfTextPage
    val currentTextIdentity by rememberUpdatedState(pageText?.identity)
    val pageCount = pageText?.identity?.pageCount ?: 0
    var copiedAll by remember(pageText?.identity) { mutableStateOf(false) }
    LaunchedEffect(copiedAll) {
        if (copiedAll) {
            delay(1_600)
            copiedAll = false
        }
    }
    FloeActionSheet(
        visible = true,
        onDismiss = onDismiss,
        maxCardWidth = 760.dp,
        maxCardHeightFraction = 0.92f,
    ) {
        Column(
            Modifier.fillMaxSize().padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FloeText(stringResource(R.string.notes_pdf_text_sheet_title), style = Floe.typography.title)
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(
                    stringResource(
                        if (copiedAll) R.string.notes_pdf_text_copied else R.string.notes_pdf_text_copy_all,
                    ),
                    onClick = {
                        val text = session.copyablePdfPageText()
                        if (text != null) {
                            clipboard.setText(AnnotatedString(text))
                            copiedAll = true
                        }
                    },
                    enabled = pageText != null && pageText.text.isNotBlank(),
                )
                Spacer(Modifier.weight(1f))
                FloeCapsuleAction(stringResource(R.string.notes_done), onClick = onDismiss)
            }
            if (pageCount > 0) {
                FloeText(
                    stringResource(
                        R.string.notes_pdf_text_page_identity,
                        pdfPageNumber,
                        pageCount,
                    ),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
            FloeDivider()
            if (pageText == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    FloeText(
                        session.pdfTextNotice?.let { pdfTextNoticeText(it) }
                            ?: stringResource(R.string.notes_pdf_text_failed),
                        style = Floe.typography.body,
                        color = Floe.colors.secondaryLabel,
                    )
                }
            } else {
                FloeText(
                    stringResource(R.string.notes_pdf_text_sheet_hint),
                    style = Floe.typography.metadata,
                    color = Floe.colors.tertiaryLabel,
                )
                if (pageText.truncated) {
                    FloeText(
                        stringResource(R.string.notes_pdf_text_truncated),
                        style = Floe.typography.metadata,
                        color = Floe.colors.pending,
                    )
                }
                val displayText = pageText.text
                AndroidView(
                    factory = { ctx ->
                        object : TextView(ctx) {
                            override fun onTextContextMenuItem(id: Int): Boolean {
                                // The platform Copy/Share path must fence at the action,
                                // independently of the visible-state refresh timer.
                                if (session.currentPdfTextIdentity() != currentTextIdentity ||
                                    session.copyablePdfPageText() != text?.toString()
                                ) return false
                                return super.onTextContextMenuItem(id)
                            }
                        }.apply {
                            setTextIsSelectable(true)
                            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                            setTextColor(textColor)
                            setBackgroundColor(android.graphics.Color.TRANSPARENT)
                            setPadding(
                                (16 * density).roundToInt(),
                                (8 * density).roundToInt(),
                                (16 * density).roundToInt(),
                                (24 * density).roundToInt(),
                            )
                            setLineSpacing(0f, 1.18f)
                            isVerticalScrollBarEnabled = true
                        }
                    },
                    update = { view ->
                        if (view.text?.toString() != displayText) {
                            view.setTextIsSelectable(false)
                            view.text = displayText
                            view.setTextIsSelectable(true)
                        }
                        view.setTextColor(textColor)
                        view.setPadding(
                            (16 * density).roundToInt(),
                            (8 * density).roundToInt(),
                            (16 * density).roundToInt(),
                            (24 * density).roundToInt(),
                        )
                    },
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
            }
        }
    }
}

@Composable
private fun pdfTextNoticeText(notice: NotesPdfTextNotice): String = stringResource(
    when (notice) {
        NotesPdfTextNotice.NO_TEXT -> R.string.notes_pdf_text_no_text
        NotesPdfTextNotice.NATIVE_TEXT_UNSUPPORTED -> R.string.notes_pdf_text_selection_unavailable
        NotesPdfTextNotice.PROTECTED -> R.string.notes_pdf_text_protected
        NotesPdfTextNotice.SOURCE_CHANGED -> R.string.notes_pdf_text_stale
        NotesPdfTextNotice.PAGE_OUT_OF_RANGE -> R.string.notes_pdf_text_page_gone
        NotesPdfTextNotice.GEOMETRY_MISMATCH -> R.string.notes_pdf_text_geometry_unavailable
        NotesPdfTextNotice.BACKEND_FAILED -> R.string.notes_pdf_text_failed
        NotesPdfTextNotice.CANCELLED -> R.string.notes_pdf_text_cancelled
    },
)
